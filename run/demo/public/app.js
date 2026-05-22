const state = {
  items: [],
  activeId: null
};

const els = {
  status: document.querySelector("#status"),
  viewer: document.querySelector("#viewer"),
  thumbs: document.querySelector("#thumbs"),
  meta: document.querySelector("#meta"),
  refreshBtn: document.querySelector("#refreshBtn")
};

function formatBytes(value) {
  const size = Number(value || 0);
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  if (size < 1024 * 1024 * 1024) return `${(size / 1024 / 1024).toFixed(1)} MB`;
  return `${(size / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function setStatus(text, kind = "") {
  els.status.textContent = text;
  els.status.className = `status ${kind}`.trim();
}

function renderThumbs() {
  els.thumbs.innerHTML = "";
  for (const item of state.items) {
    const button = document.createElement("button");
    button.className = `thumb ${item.id === state.activeId ? "is-active" : ""}`;
    button.type = "button";
    button.title = item.name;

    const preview = document.createElement("div");
    preview.className = "thumb-preview";
    if (item.kind === "image") {
      const img = document.createElement("img");
      img.src = item.media_url;
      img.alt = "";
      img.loading = "lazy";
      preview.appendChild(img);
    } else {
      const mark = document.createElement("span");
      mark.className = "video-mark";
      mark.textContent = "PLAY";
      preview.appendChild(mark);
    }

    const copy = document.createElement("div");
    const name = document.createElement("div");
    name.className = "thumb-name";
    name.textContent = item.name;
    const sub = document.createElement("div");
    sub.className = "thumb-sub";
    sub.textContent = `${item.kind.toUpperCase()} · ${formatBytes(item.size)}`;
    copy.append(name, sub);

    button.append(preview, copy);
    button.addEventListener("click", () => setActive(item.id));
    els.thumbs.appendChild(button);
  }
}

function renderActive() {
  const item = state.items.find((entry) => entry.id === state.activeId);
  els.viewer.innerHTML = "";
  if (!item) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "等待 Teldrive 媒体";
    els.viewer.appendChild(empty);
    els.meta.textContent = "";
    return;
  }

  if (item.kind === "video") {
    const video = document.createElement("video");
    video.src = item.media_url;
    video.controls = true;
    video.playsInline = true;
    video.preload = "metadata";
    els.viewer.appendChild(video);
  } else {
    const img = document.createElement("img");
    img.src = item.media_url;
    img.alt = item.name;
    img.decoding = "async";
    els.viewer.appendChild(img);
  }

  els.meta.textContent = `${item.name} · ${item.mime_type} · ${formatBytes(item.size)} · ${item.id}`;
}

function setActive(id) {
  state.activeId = id;
  renderActive();
  renderThumbs();
}

async function loadCatalog() {
  setStatus("同步中");
  const response = await fetch("/api/catalog", { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`catalog ${response.status}`);
  }
  const payload = await response.json();
  state.items = payload.items || [];
  const preferred = state.items.find((item) => item.name === "001.png") || state.items[0] || null;
  state.activeId = preferred?.id || null;
  renderActive();
  renderThumbs();
  setStatus(`${state.items.length} 项`, "ok");
}

els.refreshBtn.addEventListener("click", () => {
  loadCatalog().catch((error) => {
    console.error(error);
    setStatus("失败", "error");
  });
});

loadCatalog().catch((error) => {
  console.error(error);
  setStatus("失败", "error");
});
