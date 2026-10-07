// 承認待ちの一覧の画面。ページを移らずに、タブの切り替え・判断・元に戻す操作を行う。
// 案の文字列は textContent で入れ、innerHTML には入れない。
// カードの構造は inbox_server.py の render_card と同じにする。
(function () {
  "use strict";

  var STATUS_ORDER = ["pending", "approved", "hold", "rejected", "applied"];
  var STATUS_LABEL = {
    pending: "承認待ち", approved: "承認済み", hold: "保留", rejected: "却下", applied: "反映済み"
  };
  var BUTTON_LABEL = {
    approved: "承認する", hold: "保留にする", rejected: "却下する", pending: "承認待ちに戻す"
  };
  var DONE_LABEL = {
    approved: "承認しました", hold: "保留にしました", rejected: "却下しました", pending: "承認待ちに戻しました"
  };
  var POLL_MS = 3000;
  var TOAST_MS = 8000;
  var NEW_MS = 6000; // 新着の印を付けておく時間

  var cardsEl = document.getElementById("cards");
  var toastEl = document.getElementById("toast");
  var offlineEl = document.getElementById("offline");
  if (!cardsEl || !toastEl) {
    return;
  }
  var current = cardsEl.getAttribute("data-status") || "pending";
  var items = null; // 直近に取得した案の一覧
  var toastTimer = null;
  var busy = false;
  var lastText = null; // 直近に取得した応答の本文。変わっていなければ描き直さない
  var knownIds = null; // 直近に取得した案の id。最初の取得の前は null
  var newUntil = {}; // 新着の印を外す時刻（id ごと）
  var arrived = 0; // 判断の知らせを出している間に届いた承認待ちの件数
  var loading = false;
  var pollTimer = null;

  function el(tag, attrs, text) {
    var e = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        e.setAttribute(k, attrs[k]);
      });
    }
    if (text !== undefined && text !== null) {
      e.textContent = text;
    }
    return e;
  }

  function emptyMessage(status) {
    if (status === "pending") {
      return "承認待ちの変更はありません。定期実行や会話で案が作られると、ここに表示されます。";
    }
    return STATUS_LABEL[status] + "の変更はありません。";
  }

  function diffClass(line) {
    if (line.kind === "header") {
      return line.text.indexOf("@@") === 0 ? "hunk" : "file";
    }
    if (line.kind === "add" || line.kind === "del") {
      return line.kind;
    }
    return "";
  }

  function buildCard(item, status) {
    var card = el("article", { "class": "card", id: item.id, "data-slug": item.slug, "data-status": item.status });
    var head = el("div", { "class": "card-head" });
    head.appendChild(el("span", { "class": "num" }, item.number));
    head.appendChild(el("h2", null, item.heading || "（見出しなし）"));
    head.appendChild(el("span", { "class": "status" }, STATUS_LABEL[item.status] || item.status));
    card.appendChild(head);
    card.sig = status + "\n" + JSON.stringify(item);

    var dl = el("dl", { "class": "facts" });
    function fact(label, node) {
      dl.appendChild(el("dt", null, label));
      var dd = el("dd");
      dd.appendChild(node);
      dl.appendChild(dd);
    }
    var targets = el("span", { "class": "path" });
    if (item.targets.length === 0) {
      targets.textContent = "なし";
    }
    item.targets.forEach(function (t, i) {
      if (i > 0) {
        targets.appendChild(document.createElement("br"));
      }
      targets.appendChild(document.createTextNode(t));
    });
    fact("対象", targets);
    fact("作成日時", document.createTextNode(item.created));
    fact("出した元", document.createTextNode(item.source));
    if (item.decided) {
      fact("判断した日時", document.createTextNode(item.decided));
    }
    if (item.note && item.status === "applied") {
      fact("メモ", el("span", { "class": "text" }, item.note));
    }
    card.appendChild(dl);

    if (item.reason) {
      card.appendChild(el("h3", null, "理由"));
      card.appendChild(el("div", { "class": "text" }, item.reason));
    }
    if (item.diff.length > 0) {
      var dd = el("details", { "class": "diff" });
      dd.open = status === "pending";
      dd.appendChild(el("summary", null, "差分（" + item.diff.length + "行）"));
      var pre = el("pre", { "class": "diff" });
      item.diff.forEach(function (line) {
        pre.appendChild(el("span", { "class": diffClass(line) }, line.text || " "));
      });
      dd.appendChild(pre);
      card.appendChild(dd);
    }
    if (item.sections.length > 0) {
      var other = el("details", { "class": "others" });
      other.appendChild(el("summary", null, "その他の本文"));
      item.sections.forEach(function (sec) {
        if (sec.title) {
          other.appendChild(el("h3", null, sec.title));
        }
        other.appendChild(el("div", { "class": "text" }, sec.text));
      });
      card.appendChild(other);
    }
    var err = el("p", { "class": "error", role: "alert" });
    err.hidden = true;
    card.appendChild(err);

    if (item.status !== "applied") {
      var nid = "note-" + item.id;
      var form = el("form", { "class": "decide", method: "post", action: "/p/" + encodeURIComponent(item.slug) + "/decide" });
      form.appendChild(el("label", { "for": nid }, "メモ（任意）"));
      form.appendChild(el("p", { "class": "help", id: nid + "-help" },
        "却下の理由を書くと否認リストに残り、同じ趣旨の案が再び出されなくなります。"));
      var ta = el("textarea", { id: nid, name: "note", "aria-describedby": nid + "-help" });
      ta.value = item.note;
      form.appendChild(ta);
      var buttons = el("div", { "class": "buttons" });
      ["approved", "hold", "rejected", "pending"].forEach(function (to) {
        if (to !== item.status) {
          buttons.appendChild(el("button", { type: "submit", name: "to", value: to, "class": to }, BUTTON_LABEL[to]));
        }
      });
      form.appendChild(buttons);
      card.appendChild(form);
    }
    var link = el("p", { "class": "detail-link" });
    link.appendChild(el("a", { href: "/p/" + encodeURIComponent(item.slug) }, "案の画面で開く"));
    card.appendChild(link);
    return card;
  }

  // メモ欄に入力中（フォーカスがある、または保存した内容から変えた）なら true。
  function isEditing(card) {
    var ta = card.querySelector("textarea");
    if (!ta) {
      return false;
    }
    return document.activeElement === ta || ta.value !== ta.defaultValue;
  }

  function sortFor(status, list) {
    var out = list.filter(function (it) { return it.status === status; });
    out.sort(function (a, b) {
      var r = a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
      return status === "pending" ? r : -r;
    });
    return out;
  }

  function renderTabs() {
    var counts = {};
    STATUS_ORDER.forEach(function (s) { counts[s] = 0; });
    items.forEach(function (it) {
      if (counts[it.status] !== undefined) {
        counts[it.status] += 1;
      }
    });
    document.querySelectorAll("nav.tabs a[data-status]").forEach(function (a) {
      var s = a.getAttribute("data-status");
      var c = a.querySelector(".count");
      if (c) {
        c.textContent = String(counts[s] || 0);
      }
      if (s === current) {
        a.setAttribute("aria-current", "page");
      } else {
        a.removeAttribute("aria-current");
      }
    });
    document.title = STATUS_LABEL[current] + " | 承認待ちの変更";
  }

  // 新着の印を付け外しする。印は見出しの横の札とカードの枠で示す。
  function markNew(card) {
    var on = (newUntil[card.id] || 0) > Date.now();
    var label = card.querySelector(".new-label");
    card.classList.toggle("new", on);
    if (on && !label) {
      card.querySelector(".card-head").appendChild(el("span", { "class": "new-label" }, "新着"));
    } else if (!on && label) {
      label.parentNode.removeChild(label);
    }
  }

  // 作り直したカードで、元のカードの <details> の開閉を引き継ぐ。
  function keepOpenState(from, to) {
    ["details.diff", "details.others"].forEach(function (sel) {
      var a = from.querySelector(sel);
      var b = to.querySelector(sel);
      if (a && b) {
        b.open = a.open;
      }
    });
  }

  // 一覧を描き直す。内容が変わっていないカードと、keepEditing のときの入力中のカードは
  // 今の要素をそのまま残し、位置が変わったものだけを動かす（スクロール・フォーカス・開閉を保つ）。
  function renderCards(keepEditing) {
    var old = {};
    cardsEl.querySelectorAll("article.card").forEach(function (card) {
      old[card.id] = card;
    });
    var shown = sortFor(current, items);
    var nodes = shown.map(function (it) {
      var prev = old[it.id];
      var node;
      if (prev && (prev.sig === current + "\n" + JSON.stringify(it) || (keepEditing && isEditing(prev)))) {
        node = prev;
      } else {
        node = buildCard(it, current);
        if (prev) {
          keepOpenState(prev, node);
        }
      }
      markNew(node);
      return node;
    });
    if (nodes.length === 0) {
      cardsEl.textContent = "";
      cardsEl.appendChild(el("p", { "class": "empty" }, emptyMessage(current)));
    } else {
      var keep = {};
      nodes.forEach(function (n) { keep[n.id] = true; });
      Array.prototype.slice.call(cardsEl.children).forEach(function (c) {
        if (!keep[c.id] || c.tagName !== "ARTICLE") {
          cardsEl.removeChild(c);
        }
      });
      nodes.forEach(function (n, i) {
        var at = cardsEl.children[i] || null;
        if (at !== n) {
          cardsEl.insertBefore(n, at);
        }
      });
    }
    cardsEl.setAttribute("data-status", current);
  }

  function setOffline(on) {
    if (offlineEl) {
      offlineEl.hidden = !on;
    }
  }

  function load() {
    return fetch("/api/proposals", { headers: { Accept: "application/json" }, cache: "no-store" })
      .then(function (r) {
        if (!r.ok) {
          throw new Error("一覧を取得できませんでした（状態コード " + r.status + "）");
        }
        return r.text();
      })
      .then(function (text) {
        setOffline(false);
        if (text === lastText && items) {
          return false;
        }
        var data = JSON.parse(text);
        lastText = text;
        var added = [];
        if (knownIds) {
          data.forEach(function (it) {
            if (!knownIds[it.id]) {
              added.push(it);
            }
          });
        }
        knownIds = {};
        data.forEach(function (it) { knownIds[it.id] = true; });
        items = data;
        noticeAdded(added);
        return true;
      }, function (e) {
        setOffline(true);
        throw e;
      });
  }

  // 前回の取得の後に増えた案に新着の印を付け、承認待ちが増えたら画面の下で知らせる。
  function noticeAdded(added) {
    var now = Date.now();
    var pending = 0;
    added.forEach(function (it) {
      newUntil[it.id] = now + NEW_MS;
      if (it.status === "pending") {
        pending += 1;
      }
    });
    if (added.length > 0) {
      setTimeout(function () {
        cardsEl.querySelectorAll("article.card.new").forEach(markNew);
      }, NEW_MS + 50);
    }
    if (pending > 0) {
      announceArrived(pending);
    }
  }

  function announceArrived(n) {
    // 「元に戻す」を出している間は上書きせず、その知らせが消えてから出す
    if (!toastEl.hidden && toastEl.querySelector("button")) {
      arrived += n;
      return;
    }
    arrived = 0;
    showToast("承認待ちが " + n + " 件届きました", null);
  }

  // keepEditing のとき、入力中のカードは今の要素をそのまま残す。中身が変わっていなければ描き直さない。
  function refresh(keepEditing) {
    return load().then(function (changed) {
      if (changed) {
        renderTabs();
        renderCards(keepEditing);
      }
    });
  }

  function post(slug, to, note) {
    return fetch("/api/proposals/" + encodeURIComponent(slug) + "/decide", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ to: to, note: note })
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (data) {
        if (!r.ok) {
          throw new Error(data.error || ("操作できませんでした（状態コード " + r.status + "）"));
        }
        return data;
      });
    });
  }

  function replaceItem(updated) {
    for (var i = 0; i < items.length; i++) {
      if (items[i].id === updated.id) {
        items[i] = updated;
        return;
      }
    }
    items.push(updated);
  }

  function hideToast() {
    if (toastTimer) {
      clearTimeout(toastTimer);
      toastTimer = null;
    }
    toastEl.hidden = true;
    toastEl.textContent = "";
  }

  function showToast(message, undo) {
    hideToast();
    toastEl.appendChild(el("span", null, message));
    if (undo) {
      var b = el("button", { type: "button" }, "元に戻す");
      b.addEventListener("click", function () {
        hideToast();
        undo();
        if (arrived > 0) {
          announceArrived(arrived);
        }
      });
      toastEl.appendChild(b);
    }
    toastEl.hidden = false;
    toastTimer = setTimeout(function () {
      hideToast();
      if (arrived > 0) {
        announceArrived(arrived);
      }
    }, TOAST_MS);
  }

  function setBusy(card, on) {
    card.querySelectorAll("button, textarea").forEach(function (x) {
      x.disabled = on;
    });
  }

  function showError(card, message) {
    var p = card.querySelector("p.error");
    p.textContent = message;
    p.hidden = false;
  }

  function decide(card, to) {
    var slug = card.getAttribute("data-slug");
    var before = null;
    items.forEach(function (it) {
      if (it.id === card.id) {
        before = it;
      }
    });
    var ta = card.querySelector("textarea");
    var note = ta ? ta.value : "";
    var errEl = card.querySelector("p.error");
    errEl.hidden = true;
    setBusy(card, true);
    busy = true;
    post(slug, to, note).then(function (updated) {
      busy = false;
      replaceItem(updated);
      if (updated.status !== current) {
        card.parentNode.removeChild(card);
      }
      renderTabs();
      renderCards(true);
      var undo = null;
      if (before && before.status !== "applied") {
        undo = function () {
          post(slug, before.status, before.note).then(function (restored) {
            replaceItem(restored);
            renderTabs();
            renderCards(true);
            showToast(updated.number + " を元に戻しました", null);
          }, function (e) {
            showToast(updated.number + " を元に戻せませんでした。" + e.message, null);
          });
        };
      }
      showToast(updated.number + " を" + DONE_LABEL[to], undo);
    }, function (e) {
      busy = false;
      setBusy(card, false);
      showError(card, e.message || "操作できませんでした。");
      if (ta) {
        ta.focus();
      }
    });
  }

  // フォームの送信をすべて fetch に置き換える（ボタンは submit のままにし、JavaScript が無いときはフォームで送る）。
  cardsEl.addEventListener("submit", function (ev) {
    var form = ev.target;
    var card = form.closest("article.card");
    var btn = ev.submitter;
    if (!card || !btn || !btn.value || !items) {
      return;
    }
    ev.preventDefault();
    decide(card, btn.value);
  });

  document.querySelectorAll("nav.tabs a[data-status]").forEach(function (a) {
    a.addEventListener("click", function (ev) {
      if (ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey || ev.button !== 0) {
        return;
      }
      ev.preventDefault();
      current = a.getAttribute("data-status");
      history.replaceState(null, "", "/?status=" + encodeURIComponent(current));
      hideToast();
      if (items) {
        renderTabs();
        renderCards(false);
      }
      refresh(false).catch(function () { /* 描き直せなくても今の表示を残す */ });
    });
  });

  function highlightHash() {
    var id = decodeURIComponent(location.hash.replace(/^#/, ""));
    if (!id) {
      return;
    }
    var card = document.getElementById(id);
    if (!card || !card.classList.contains("card")) {
      return;
    }
    card.classList.add("highlight");
    card.scrollIntoView({ block: "start" });
  }
  window.addEventListener("hashchange", highlightHash);

  // 画面が表示されている間だけ、POLL_MS ごとに取り直す。取得中は重ねて送らない。
  function poll() {
    if (pollTimer) {
      clearTimeout(pollTimer);
      pollTimer = null;
    }
    if (document.hidden) {
      return;
    }
    if (!busy && !loading) {
      loading = true;
      refresh(true).catch(function () { /* 次の回に取り直す */ }).then(function () {
        loading = false;
        schedule();
      });
      return;
    }
    schedule();
  }

  function schedule() {
    if (pollTimer) {
      clearTimeout(pollTimer);
    }
    pollTimer = document.hidden ? null : setTimeout(poll, POLL_MS);
  }

  document.addEventListener("visibilitychange", poll);
  window.addEventListener("focus", poll);

  // 初めの表示はサーバーが描いたカードを使い、データだけ取っておく。
  loading = true;
  load().catch(function () { /* 取れなければフォームの送信のまま使う */ }).then(function () {
    loading = false;
    schedule();
  });
  highlightHash();
})();
