// 定期実行のレポートの一覧の画面。ページを移らずに既読にする。
// カードはサーバーが描いたものを使い、ここでは作らない（inbox_server.py の render_report_card）。
(function () {
  "use strict";

  var TOAST_MS = 8000;
  var tokenEl = document.querySelector('meta[name="review-token"]');
  var token = tokenEl ? tokenEl.getAttribute("content") : "";
  var cardsEl = document.getElementById("report-cards");
  var toastEl = document.getElementById("toast");
  if (!cardsEl || !toastEl) {
    return;
  }
  var view = cardsEl.getAttribute("data-view") || "unread";
  var toastTimer = null;

  function showToast(message) {
    if (toastTimer) {
      clearTimeout(toastTimer);
    }
    toastEl.textContent = message;
    toastEl.hidden = false;
    toastTimer = setTimeout(function () {
      toastEl.hidden = true;
      toastEl.textContent = "";
    }, TOAST_MS);
  }

  function send(payload) {
    return fetch("/api/reports/read", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-Review-Token": token },
      body: JSON.stringify(payload)
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (data) {
        if (!r.ok) {
          throw new Error(data.error || ("既読にできませんでした（状態コード " + r.status + "）"));
        }
        return data;
      });
    });
  }

  function setCounts(counts) {
    document.querySelectorAll("nav.tabs a[data-view]").forEach(function (a) {
      var c = a.querySelector(".count");
      if (c) {
        c.textContent = String(counts[a.getAttribute("data-view")] || 0);
      }
    });
    document.querySelectorAll("nav.switch .unread-count").forEach(function (c) {
      c.textContent = String(counts.unread);
    });
    var all = document.getElementById("mark-all");
    if (all && counts.unread === 0) {
      all.parentNode.removeChild(all);
    }
  }

  // 既読になったカードを、未読のタブでは外し、すべてのタブでは既読の表示に変える。
  function markCard(card) {
    if (view === "unread") {
      card.parentNode.removeChild(card);
      return;
    }
    card.setAttribute("data-read", "1");
    card.classList.add("read");
    card.querySelector(".status").textContent = "既読";
    var form = card.querySelector("form.mark-read");
    if (form) {
      form.parentNode.removeChild(form);
    }
  }

  function showEmptyIfNone() {
    if (view === "unread" && !cardsEl.querySelector("article.card")) {
      cardsEl.textContent = "";
      var p = document.createElement("p");
      p.className = "empty";
      p.textContent = "未読のレポートはありません。";
      cardsEl.appendChild(p);
    }
  }

  function setBusy(form, on) {
    form.querySelectorAll("button").forEach(function (b) {
      b.disabled = on;
    });
  }

  cardsEl.addEventListener("submit", function (ev) {
    var form = ev.target;
    var card = form.closest("article.card");
    if (!card) {
      return;
    }
    ev.preventDefault();
    var key = card.getAttribute("data-path");
    var err = card.querySelector("p.error");
    err.hidden = true;
    setBusy(form, true);
    send({ paths: [key] }).then(function (data) {
      // フォーカスを失わないよう、次のカードの見出しへ移す。
      var next = card.nextElementSibling;
      markCard(card);
      setCounts(data.counts);
      showEmptyIfNone();
      var parts = key.split("/");
      showToast(parts[0] + " " + parts[1] + " を既読にしました。");
      var target = next && next.querySelector("button, summary");
      if (view === "unread" && target) {
        target.focus();
      }
    }, function (e) {
      setBusy(form, false);
      err.textContent = e.message || "既読にできませんでした。";
      err.hidden = false;
    });
  });

  var allForm = document.getElementById("mark-all");
  if (allForm) {
    allForm.addEventListener("submit", function (ev) {
      ev.preventDefault();
      setBusy(allForm, true);
      send({ all: true }).then(function (data) {
        cardsEl.querySelectorAll('article.card[data-read="0"]').forEach(markCard);
        setCounts(data.counts);
        showEmptyIfNone();
        showToast("未読のレポート " + data.marked + " 件を既読にしました。");
      }, function (e) {
        setBusy(allForm, false);
        showToast(e.message || "既読にできませんでした。");
      });
    });
  }
})();
