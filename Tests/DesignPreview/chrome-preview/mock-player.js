// Uses the real panel and real selection controls with a mocked desktop boundary.
(() => {
  const calls = [], query = new URLSearchParams(location.search), log = document.getElementById("preview-log");
  let panel;
  const fixture = {
    sessionToken: "mvd-design-preview-session",
    mediaPreview: {
      title: query.has("long") ? "A deliberately long film title about the adventures of Big Buck Bunny and the world beyond the forest" : "Big Buck Bunny — Open Movie, Full HD",
      isDirectFile: false,
      qualities: [{id:"best",label:"Best available"},{id:"1080p",label:"1080p · Full HD",height:1080},{id:"720p",label:"720p · HD",height:720}],
      formats: [
        {id:"137+140",label:"MP4 · 1080p · H.264 + AAC",hasVideo:true,hasAudio:true,container:"mp4",height:1080},
        {id:"136+140",label:"MP4 · 720p · H.264 + AAC",hasVideo:true,hasAudio:true,container:"mp4",height:720},
        {id:"248",label:"WebM · 1080p · VP9 · video only",hasVideo:true,hasAudio:false,container:"webm",height:1080},
        {id:"140",label:"M4A · AAC · 128 kbps · audio only",hasVideo:false,hasAudio:true,container:"m4a"},
        {id:"251",label:"WebM · Opus · audio only",hasVideo:false,hasAudio:true,container:"webm"}
      ]
    },
    defaultFolderName: "Default MVD downloads",
    folders: [
      {id:"135b95a7-a115-4e5d-9ccd-99c27c21b21c",name:"Travel",icon:"film"},
      {id:"d08d8ec1-7562-4d98-a38f-0a94fb1c3e14",name:"Research",icon:"folder"},
      {id:"f14be0b0-b0ce-453c-8232-88d3c14092dc",name:"Podcasts",icon:"music.note"}
    ]
  };
  const record = (type, data = {}) => { calls.push({type,...structuredClone(data)}); log.textContent = JSON.stringify(calls.at(-1),null,2); };
  function open() {
    panel?.remove();
    panel = __MVDOverlayUI.panel({
      title: "Big Buck Bunny — Open Movie", sourceLabel: "youtube.com · Selected video",
      async resolve() { record("mockResolve"); if (query.has("error")) throw new Error("Design fixture: MVD could not connect. Open the desktop app and try again."); return structuredClone(fixture); },
      async enqueue(selection) { record("mockEnqueue",selection); return {accepted:true,jobID:"e48b2755-d890-44f3-a67e-b70b55b4aa7c"}; },
      async disable() { record("mockDisableWebsite"); }, dismiss() { record("mockHidePlayerButton"); }
    });
  }
  globalThis.__MVDPreview = {calls,fixture,open};
  document.getElementById("reopen").addEventListener("click",open);
  open();
})();
