(() => {
    const hosts = new Set(["m.youtube.com", "www.youtube.com", "youtube.com", "youtu.be"]);
    function videoURL(value) {
        try {
            const u = new URL(value, location.href);
            if (u.protocol !== "https:" || !hosts.has(u.hostname)) return;
            const id = u.hostname === "youtu.be" ? u.pathname.slice(1)
                : u.pathname === "/watch" ? u.searchParams.get("v")
                : u.pathname.match(/^\/(?:live|shorts|embed)\/([^/]+)$/)?.[1];
            if (id && /^[A-Za-z0-9_-]{11}$/.test(id)) return u.href;
        } catch {}
    }
    document.addEventListener("click", event => {
        if (event.defaultPrevented || event.button !== 0) return;
        const a = event.composedPath().find(node => node.tagName === "A" && node.href);
        if (!a) return;
        const url = videoURL(a.href);
        if (!url) return;
        const card = a.closest("ytm-video-with-context-renderer,ytm-compact-video-renderer,ytm-rich-item-renderer");
        const title = card?.querySelector("h3,h4,.media-item-headline")?.textContent
            || a.getAttribute("title") || a.getAttribute("aria-label") || a.textContent || "";
        event.preventDefault();
        event.stopImmediatePropagation();
        window.webkit.messageHandlers.newTube.postMessage({url, title: title.trim()});
    }, true);
    const style = document.createElement("style");
    style.textContent = "ytm-reel-shelf-renderer,ytm-shorts-lockup-view-model,ytm-reel-item-renderer,ytm-pivot-bar-item-renderer:has(a[href^='/shorts']){display:none!important}";
    (document.head || document.documentElement).appendChild(style);
})();
