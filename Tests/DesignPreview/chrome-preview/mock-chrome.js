// Design fixture only. This file is never packaged with MVD Companion.
(() => {
  if (!["127.0.0.1", "localhost", "[::1]"].includes(location.hostname)) throw new Error("Use a local HTTP server for this preview.");
  const query = new URLSearchParams(location.search), calls = [], listeners = [];
  const movies = [
    { name: "Big Buck Bunny — Open Movie, Full HD", file: "BigBuckBunny", videoID: "aqz-KE-bpKQ", type: "MP4" },
    { name: "Tears of Steel — Official Blender Open Movie", file: "TearsOfSteel", videoID: "R6MlUcmOul8", type: "HLS" },
    { name: "Elephants Dream — A Journey Beyond the Machine", file: "ElephantsDream", videoID: "6v2L2UGZJAM", type: "MP4" }
  ];
  const page = {
    tabID: 17, pageURL: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", title: "Open movie collection — MVD design preview",
    usableMediaCount: 3, protectedMedia: 0, inaccessibleMedia: 0, sitePermission: false,
    disabled: query.has("disabled"), frameOrigins: ["https://storage.googleapis.com"],
    candidates: movies.map((movie,index) => ({
      id: `preview-video-${index+1}`, assetID: `preview-player-${index+1}`, frameID: 0,
      title: movie.name, titleSource: "Video title", pageTitle: "Open movie collection — MVD design preview",
      thumbnailURL: `https://i.ytimg.com/vi/${movie.videoID}/hqdefault.jpg`, thumbnailSource: "Video poster",
      url: `https://storage.googleapis.com/gtv-videos-bucket/sample/${movie.file}.mp4`, mediaType: movie.type, isMedia: true,
      usable: true, protected: false, discovery: "DOM + network metadata", sourceLabel: "storage.googleapis.com",
      variants: [{url:`https://storage.googleapis.com/gtv-videos-bucket/sample/${movie.file}.mp4`}]
    }))
  };
  if (query.has("empty")) { page.candidates = []; page.usableMediaCount = 0; }
  if (query.has("long")) page.candidates[0].title = "A deliberately long video title about mountains, forests, the ocean, and the stories we discover while exploring the world";
  globalThis.__MVDPreview = { calls, page, emit() { for (const listener of listeners) listener({type:"registryChanged",tabID:page.tabID}, {id:"mvd-design-preview"}); } };
  globalThis.chrome = {
    runtime: {
      id: "mvd-design-preview", onMessage: { addListener(callback) { listeners.push(callback); } },
      async sendMessage(message) {
        calls.push(structuredClone(message));
        if (["inspect","snapshot","permissionsChanged"].includes(message.type)) return {ok:true,...structuredClone(page)};
        if (message.type === "state") return {ok:true};
        if (message.type === "connection") return {ok:true,connected:!query.has("offline"),reviewAvailable:true,serviceVersion:"0.4.0",...(query.has("offline") ? {error:"Design fixture: desktop unavailable"} : {})};
        if (message.type === "toggleSite") { page.disabled = message.disabled; return {ok:true,...structuredClone(page)}; }
        if (["openReview","showPlayerPanel"].includes(message.type)) return {ok:true,opened:true};
        if (["enqueue","retry"].includes(message.type)) return {ok:true,accepted:true,jobID:"e48b2755-d890-44f3-a67e-b70b55b4aa7c"};
        throw new Error(`Unexpected preview command: ${message.type}`);
      }
    },
    permissions: { async request(request) { calls.push({type:"mockPermissionRequest",...structuredClone(request)}); page.sitePermission = true; return true; } }
  };
})();
