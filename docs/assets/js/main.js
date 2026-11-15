/* DreamPlayer site — progressive enhancement only. Everything works
   without JS: the tabs are two stacked blocks, the lightbox never opens. */

(function () {
  "use strict";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------------------------------------------------- sticky nav -- */

  var nav = document.getElementById("nav");

  function onScroll() {
    if (nav) nav.classList.toggle("is-stuck", window.scrollY > 8);
  }

  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* --------------------------------------------------- mobile menu -- */

  var toggle = document.getElementById("navToggle");
  var links = document.getElementById("navLinks");

  if (toggle && links) {
    toggle.addEventListener("click", function () {
      var open = links.classList.toggle("is-open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });

    // Close after tapping a link, otherwise the menu covers the target.
    links.addEventListener("click", function (e) {
      if (e.target.tagName === "A") {
        links.classList.remove("is-open");
        toggle.setAttribute("aria-expanded", "false");
      }
    });
  }

  /* ------------------------------------------------------- reveal -- */

  var revealables = document.querySelectorAll(".reveal");

  if (reduced || !("IntersectionObserver" in window)) {
    revealables.forEach(function (el) { el.classList.add("is-in"); });
  } else {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-in");
          io.unobserve(entry.target);
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.06 }
    );

    revealables.forEach(function (el) { io.observe(el); });
  }

  /* --------------------------------------------------------- tabs -- */

  var tabs = document.querySelectorAll(".tab");
  var panels = document.querySelectorAll(".panel");

  tabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      var want = tab.dataset.tab;

      tabs.forEach(function (t) {
        var on = t === tab;
        t.classList.toggle("is-active", on);
        t.setAttribute("aria-selected", on ? "true" : "false");
      });

      panels.forEach(function (p) {
        p.classList.toggle("is-active", p.id === want);
      });
    });
  });

  /* ----------------------------------------------------- lightbox -- */

  var box = document.getElementById("lightbox");
  var boxImg = document.getElementById("lightboxImg");
  var boxClose = document.getElementById("lightboxClose");

  function closeBox() {
    if (!box) return;
    box.classList.remove("is-open");
    document.body.style.overflow = "";
  }

  if (box) {
    document.querySelectorAll(".shot").forEach(function (shot) {
      shot.addEventListener("click", function () {
        var src = shot.dataset.full;
        var img = shot.querySelector("img");
        if (!src) return;
        boxImg.src = src;
        boxImg.alt = img ? img.alt : "";
        box.classList.add("is-open");
        document.body.style.overflow = "hidden";
      });
    });

    box.addEventListener("click", function (e) {
      if (e.target === box || e.target === boxClose) closeBox();
    });

    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closeBox();
    });
  }
})();
