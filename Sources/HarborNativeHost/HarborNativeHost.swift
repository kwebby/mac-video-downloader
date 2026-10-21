import Foundation
import HarborCore
import Darwin

@main
struct HarborNativeHost {
    static func main() async {
        // Broken Chrome pipes should terminate the adapter, never the broker or accepted jobs.
        signal(SIGPIPE, SIG_IGN)
        let callerOrigin: String
        do { callerOrigin = try HostRegistration.validateCaller() }
        catch {
            diagnostic("Could not verify this Chrome companion's exact native-host registration. Check its extension ID, installation, and filesystem access.")
            exit(1)
        }
        while true {
            do {
                guard let payload = try NativeMessageFraming.read(from: .standardInput) else { return }
                let response = await process(payload, callerOrigin: callerOrigin)
                try NativeMessageFraming.write(response.bounded(), to: .standardOutput)
                // Deliver the durable broker acknowledgement before attempting
                // UI activation. A launch failure must not turn an accepted job
                // into a failed handoff or encourage a duplicate retry.
                if let request = try? HostRequest.decode(payload) {
                    do { try await ReviewApplication.openAcceptedDownload(request, response: response) }
                    catch { diagnostic("The download was accepted, but MVD could not be brought forward. Open the app to view its progress.") }
                }
            } catch {
                diagnostic("Native messaging framing failed or Chrome disconnected.")
                return
            }
        }
    }

    private static func process(_ payload: Data, callerOrigin: String) async -> HostResponse {
        let request: HostRequest
        do { request = try HostRequest.decode(payload) }
        catch {
            // A malformed request never receives a guessed enqueue acknowledgment.
            return HostResponse(requestID: HostRequest.validRequestID(in: payload), error: "Invalid companion request. Update the app and companion together.")
        }
        do {
            if request.command == "openReview" {
                try await ReviewApplication.open(request)
                return HostResponse(requestID: request.requestID, opened: true)
            }
            let brokerRequest = try request.brokerRequest()
            try await BrokerLauncher.ensureRunning()
            let result = try await BrokerClient().send(brokerRequest)
            guard result.requestID == request.requestID else { throw NativeMessageError.unavailableBroker }
            if let error = result.error {
                return HostResponse(requestID: request.requestID, error: HostErrorSanitizer.message(error))
            }
            if ["enqueue", "enqueueMedia"].contains(request.command), result.jobID == nil { throw NativeMessageError.unavailableBroker }
            if request.command == "hello" {
                do { try ChromeCompanionConnection.recordHello(origin: callerOrigin) }
                catch { diagnostic("Could not save companion connection status for the desktop app.") }
            }
            let includesFolders = ["hello", "listFolders", "resolveMedia"].contains(request.command)
            return HostResponse(requestID: request.requestID, jobID: result.jobID,
                                jobs: request.command == "list" ? Array(result.jobs.prefix(100)).map(HostJob.init) : nil,
                                reviewAvailable: request.command == "hello" ? (try? ReviewApplication.bundledApplication()) != nil : nil,
                                nextPageOffset: request.command == "list" ? result.nextPageOffset : nil,
                                totalJobCount: request.command == "list" ? result.totalJobCount : nil,
                                mediaPreview: request.command == "resolveMedia" ? result.mediaPreview : nil,
                                folders: includesFolders ? (result.folders ?? []).map(HostFolder.init) : nil,
                                defaultFolderName: includesFolders ? "Default download folder" : nil,
                                mediaPanelAvailable: request.command == "hello" ? true : nil,
                                commands: request.command == "hello" ? ["hello", "list", "listFolders", "resolveMedia", "enqueue", "enqueueMedia", "openReview"] : nil)
        } catch let error as PublicNetworkPolicyError {
            return HostResponse(requestID: request.requestID, error: error.localizedDescription)
        } catch let error as ReviewApplicationError {
            return HostResponse(requestID: request.requestID, error: error.localizedDescription)
        } catch {
            diagnostic("The desktop broker did not confirm a companion request.")
            return HostResponse(requestID: request.requestID, error: "MVD is unavailable. Open the desktop app, verify its setup, then retry this handoff.")
        }
    }

    private static func diagnostic(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(("HarborNativeHost: " + message + "\n").utf8))
    }
}
