(() => {
  'use strict';

  const RESOURCE = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'hitman_players';
  const $ = (id) => document.getElementById(id);

  let strings = {};
  let state = null;       // last state from the server
  let tab = 'board';
  let players = null;     // online players for the target list, null = not loaded yet
  let pending = null;     // 'place' while we wait for the server's answer
  let form = freshForm();
  let place = null;       // references into the post-a-contract form
  let toastTimer = null;
  let ticker = null;
  let hudEnd = 0;

  // ---------------------------------------------------------------- utils
  function post(name, data) {
    return fetch(`https://${RESOURCE}/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {}),
    }).catch(() => {});
  }

  // %s / %d are filled from the extra arguments.
  function t(key, ...args) {
    const text = strings[key] !== undefined ? String(strings[key]) : key;
    let i = 0;
    return text.replace(/%%|%[ds]/g, (m) => (m === '%%' ? '%' : (i < args.length ? args[i++] : '')));
  }

  function applyStrings() {
    document.querySelectorAll('[data-i18n]').forEach((el) => {
      const key = el.getAttribute('data-i18n');
      if (strings[key] !== undefined) el.textContent = strings[key];
    });
  }

  function money(n) {
    const currency = (state && state.currency) || '$';
    return currency + Math.round(Number(n) || 0).toLocaleString('en-US');
  }

  function clock(seconds) {
    const s = Math.max(0, Math.floor(seconds));
    const hours = Math.floor(s / 3600);
    const minutes = Math.floor((s % 3600) / 60);
    const secs = String(s % 60).padStart(2, '0');
    return hours > 0
      ? `${hours}:${String(minutes).padStart(2, '0')}:${secs}`
      : `${minutes}:${secs}`;
  }

  function accountLabel(account) {
    return strings[`ui_${account}`] || account;
  }

  // Tiny DOM builder. Text always goes through textContent, never innerHTML.
  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    if (props) {
      for (const [key, value] of Object.entries(props)) {
        if (value === undefined || value === null || value === false) continue;
        if (key === 'text') el.textContent = value;
        else if (key === 'class') el.className = value;
        else if (key === 'value') el.value = value;
        else if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2), value);
        else el.setAttribute(key, value === true ? '' : value);
      }
    }
    for (const child of children.flat()) {
      if (child === undefined || child === null || child === false) continue;
      el.append(child.nodeType ? child : document.createTextNode(String(child)));
    }
    return el;
  }

  // an element whose text counts down every second
  function countdown(seconds, tag = 'strong') {
    return h(tag, { 'data-end': Date.now() + Math.max(0, seconds) * 1000, text: clock(seconds) });
  }

  function emptyBlock(message, button) {
    return h('div', { class: 'empty' }, h('div', { text: message }), button);
  }

  function freshForm() {
    return { targetId: null, target: '', reward: 0, description: '', account: null, filter: '' };
  }

  // ----------------------------------------------------------------- toast
  function showToast(toast) {
    if (!toast || !toast.text) return;
    const el = $('toast');
    el.textContent = toast.text;
    el.classList.toggle('err', toast.ok === false);
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 4500);
  }

  // ----------------------------------------------------------------- strip
  function renderStrip() {
    const s = state;
    const cells = [];

    for (const account of s.limits.accounts) {
      cells.push(h('div', { class: 'cell' },
        h('span', { class: 'label', text: accountLabel(account) }),
        h('b', { text: money(s.balances[account]) })));
    }
    cells.push(
      h('div', { class: 'cell' },
        h('span', { class: 'label', text: t('ui_stat_kills') }), h('b', { text: s.stats.kills })),
      h('div', { class: 'cell' },
        h('span', { class: 'label', text: t('ui_stat_earned') }), h('b', { text: money(s.stats.earned) })),
      h('div', { class: 'cell' },
        h('span', { class: 'label', text: t('ui_stat_placed') }), h('b', { text: s.stats.placed })),
    );

    const toggle = h('button', {
      class: 'switch',
      type: 'button',
      role: 'switch',
      id: 'duty-switch',
      'aria-checked': String(!!s.duty),
      'aria-label': t('ui_duty'),
      disabled: !s.canWork,
      onclick: () => post('duty', { on: !state.duty }),
    });
    cells.push(h('div', { class: 'cell duty' },
      h('div', {}, h('span', { class: 'label', text: t('ui_duty') }), h('b', { text: s.duty ? 'ON' : 'OFF' })),
      toggle));

    $('strip').replaceChildren(...cells);
  }

  function renderTabs() {
    document.querySelectorAll('#tabs button').forEach((button) => {
      const name = button.dataset.tab;
      button.setAttribute('aria-selected', String(name === tab));
      button.dataset.dot = String(name === 'active' && !!(state && state.active));
    });
  }

  // ----------------------------------------------------------------- board
  function contractCard(c) {
    const blocked = !c.targetOnline || !!state.active || state.cooldowns.abandon > 0;
    return h('article', { class: 'card' },
      h('div', { class: 'card-top' },
        h('span', { class: 'name', text: c.target }),
        h('span', { class: 'money', text: money(c.payout) })),
      c.targetOnline ? null : h('div', {}, h('span', { class: 'chip warn', text: t('ui_target_offline') })),
      h('p', { class: `quote${c.description ? '' : ' none'}`, text: c.description || t('ui_no_description') }),
      h('div', { class: 'meta' }, h('span', { text: t('ui_expires') }), countdown(c.expiresIn)),
      h('button', {
        class: 'btn',
        type: 'button',
        disabled: blocked,
        text: t('ui_accept'),
        onclick: () => post('claim', { id: c.id }),
      }));
  }

  function renderBoard() {
    if (!state.canWork) return emptyBlock(t('ui_not_worker'));
    if (!state.duty) {
      return emptyBlock(t('ui_off_duty'),
        h('button', { class: 'btn', type: 'button', text: t('ui_duty'), onclick: () => post('duty', { on: true }) }));
    }
    if (!state.open.length) return emptyBlock(t('ui_board_empty'));
    return h('div', { class: 'grid' }, state.open.map(contractCard));
  }

  // ---------------------------------------------------------------- active
  function renderActive() {
    const a = state.active;
    if (!a) return emptyBlock(t('ui_active_empty'));
    return h('div', { class: 'grid' },
      h('article', { class: 'card' },
        h('div', { class: 'card-top' },
          h('span', { class: 'name', text: a.target }),
          h('span', { class: 'money', text: money(a.payout) })),
        h('p', { class: `quote${a.description ? '' : ' none'}`, text: a.description || t('ui_no_description') }),
        h('div', { class: 'meta' }, h('span', { text: t('ui_time_left') }), countdown(a.remaining)),
        h('p', { class: 'hint', text: t('ui_active_hint', a.interval) }),
        h('button', { class: 'btn ghost', type: 'button', text: t('ui_abandon'), onclick: () => post('abandon') }),
        h('p', { class: 'hint', text: t('ui_abandon_cooldown') })));
  }

  // ------------------------------------------------------------------ mine
  function renderMine() {
    if (!state.placed.length) return emptyBlock(t('ui_mine_empty'));
    return h('div', { class: 'rows' }, state.placed.map((c) => {
      const open = c.status === 'open';
      return h('div', { class: 'row' },
        h('div', {}, h('div', { class: 'name', text: c.target }), h('span', { class: `chip ${open ? 'warn' : 'hot'}`, text: open ? t('ui_status_open') : t('ui_status_claimed') })),
        h('span', { class: 'money', text: money(c.reward) }),
        open ? countdown(c.expiresIn) : h('span', {}),
        open
          ? h('button', {
            class: 'btn ghost small',
            type: 'button',
            title: t('ui_cancel_hint', money(c.refund)),
            text: `${t('ui_cancel')} (${money(c.refund)})`,
            onclick: () => post('cancel', { id: c.id }),
          })
          : h('span', {}));
    }));
  }

  // ----------------------------------------------------------------- place
  function filteredPlayers() {
    const q = form.filter.trim().toLowerCase();
    return (players || []).filter((p) => !q || p.name.toLowerCase().includes(q));
  }

  function fillPlayers() {
    if (!place || !place.list) return;
    const visible = filteredPlayers();
    place.list.replaceChildren(...visible.map((p) => h('option', {
      value: p.id,
      text: p.name,
      selected: String(form.targetId) === String(p.id),
    })));
    place.none.hidden = visible.length > 0 || players === null;
    if (form.targetId !== null && !(players || []).some((p) => String(p.id) === String(form.targetId))) {
      form.targetId = null;
    }
    syncPlace();
  }

  function rewardValid() {
    const lim = state.limits;
    return Number.isFinite(form.reward) && form.reward >= lim.minReward && form.reward <= lim.maxReward;
  }

  function targetValid() {
    return state.limits.selection === 'list' ? form.targetId !== null : form.target.trim() !== '';
  }

  // refresh the parts of the form that depend on server state, without rebuilding it
  function syncPlace() {
    if (!place || tab !== 'place') return;
    const lim = state.limits;
    const wait = state.cooldowns.place;
    const payout = Math.floor((rewardValid() ? form.reward : 0) * (100 - lim.brokerCut) / 100);
    const balance = state.balances[form.account] || 0;
    const affordable = rewardValid() && balance >= form.reward;

    place.payout.textContent = money(payout);
    place.counter.textContent = `${form.description.length}/${lim.maxDescription}`;
    place.wait.hidden = wait <= 0;
    place.wait.replaceChildren(`${t('ui_wait')} `, countdown(wait));
    place.accounts.forEach(({ button, account, amount }) => {
      button.setAttribute('aria-pressed', String(form.account === account));
      amount.textContent = money(state.balances[account]);
    });
    place.submit.disabled = !!pending || wait > 0 || !targetValid() || !rewardValid() || !affordable;
  }

  function renderPlace() {
    const lim = state.limits;
    if (form.account === null || !lim.accounts.includes(form.account)) form.account = lim.accounts[0];
    if (!form.reward) form.reward = lim.minReward;

    place = { accounts: [] };

    // target
    let targetField;
    if (lim.selection === 'list') {
      place.list = h('select', {
        size: 5,
        'aria-label': t('ui_target'),
        onchange: (event) => {
          form.targetId = event.target.value === '' ? null : event.target.value;
          syncPlace();
        },
      });
      place.none = h('p', { class: 'hint', text: t('ui_target_none'), hidden: true });
      targetField = h('label', { class: 'field' },
        h('span', { text: t('ui_target') }),
        h('input', {
          type: 'text',
          placeholder: t('ui_target_filter'),
          value: form.filter,
          oninput: (event) => {
            form.filter = event.target.value;
            fillPlayers();
          },
        }),
        place.list,
        place.none);
    } else {
      targetField = h('label', { class: 'field' },
        h('span', { text: t('ui_target') }),
        h('input', {
          type: 'text',
          placeholder: t('ui_target_input'),
          value: form.target,
          oninput: (event) => {
            form.target = event.target.value;
            syncPlace();
          },
        }));
    }

    // reward
    const rewardInput = h('input', {
      type: 'number',
      min: lim.minReward,
      max: lim.maxReward,
      step: 500,
      value: form.reward,
      oninput: (event) => {
        form.reward = Math.floor(Number(event.target.value));
        syncPlace();
      },
      onchange: (event) => {
        const clamped = Math.min(lim.maxReward, Math.max(lim.minReward, Math.floor(Number(event.target.value)) || lim.minReward));
        form.reward = clamped;
        event.target.value = clamped;
        syncPlace();
      },
    });
    const setReward = (value) => {
      form.reward = Math.min(lim.maxReward, Math.max(lim.minReward, value));
      rewardInput.value = form.reward;
      syncPlace();
    };
    const quick = h('div', { class: 'quick' },
      [5000, 10000, 50000].map((step) => h('button', {
        class: 'btn ghost small',
        type: 'button',
        text: `+${step.toLocaleString('en-US')}`,
        onclick: () => setReward((rewardValid() ? form.reward : lim.minReward) + step),
      })),
      h('button', { class: 'btn ghost small', type: 'button', text: 'Max', onclick: () => setReward(lim.maxReward) }));

    // description
    place.counter = h('div', { class: 'counter' });
    const description = h('textarea', {
      maxlength: lim.maxDescription,
      placeholder: t('ui_description_hint'),
      value: form.description,
      oninput: (event) => {
        form.description = event.target.value;
        syncPlace();
      },
    });

    // account
    const accountButtons = lim.accounts.map((account) => {
      const amount = h('b');
      const button = h('button', {
        class: 'account',
        type: 'button',
        'aria-pressed': 'false',
        onclick: () => {
          form.account = account;
          syncPlace();
        },
      }, accountLabel(account), amount);
      place.accounts.push({ button, account, amount });
      return button;
    });

    // summary
    place.payout = h('div', { class: 'big' });
    place.wait = h('div', { class: 'notice', hidden: true });
    place.submit = h('button', {
      class: 'btn',
      type: 'button',
      text: t('ui_submit'),
      onclick: () => {
        if (place.submit.disabled) return;
        pending = 'place';
        syncPlace();
        post('place', {
          targetId: form.targetId,
          target: form.target,
          reward: form.reward,
          account: form.account,
          description: form.description,
        });
      },
    });

    $('panel').replaceChildren(h('div', { class: 'form' },
      h('div', {},
        targetField,
        h('label', { class: 'field' }, h('span', { text: t('ui_reward') }), rewardInput, quick),
        h('label', { class: 'field' }, h('span', { text: t('ui_description') }), description, place.counter)),
      h('div', {},
        h('div', { class: 'field' }, h('span', { text: t('ui_pay_from') }), h('div', { class: 'accounts' }, accountButtons)),
        h('div', { class: 'summary' },
          h('span', { class: 'label', text: t('ui_summary_hitman') }),
          place.payout,
          h('span', { class: 'hint', text: t('ui_summary_cut', lim.brokerCut) }),
          h('p', { class: 'hint', text: t('ui_summary_hold') }),
          place.wait,
          place.submit))));

    if (lim.selection === 'list') {
      fillPlayers();
      if (players === null) post('players');
    }
    syncPlace();
  }

  // ---------------------------------------------------------------- panels
  function renderPanel(force) {
    renderTabs();
    if (tab === 'place') {
      if (force || !place || !$('panel').contains(place.submit)) renderPlace();
      else syncPlace();
      return;
    }
    place = null;
    const view = { board: renderBoard, active: renderActive, mine: renderMine }[tab];
    $('panel').replaceChildren(view());
    updateTimers();
  }

  function showTab(name) {
    tab = name;
    renderPanel(true);
  }

  function defaultTab() {
    if (state.active) return 'active';
    return state.canWork && state.duty ? 'board' : 'place';
  }

  // ---------------------------------------------------------------- timers
  function updateTimers() {
    document.querySelectorAll('[data-end]').forEach((el) => {
      el.textContent = clock((Number(el.dataset.end) - Date.now()) / 1000);
    });
    if (!$('hud').hidden && hudEnd) {
      const seconds = (hudEnd - Date.now()) / 1000;
      const el = $('hud-time');
      el.textContent = clock(seconds);
      el.classList.toggle('low', seconds < 120);
    }
  }

  function ensureTicker() {
    if (!ticker) ticker = setInterval(updateTimers, 1000);
  }

  // ------------------------------------------------------------------- hud
  const SIGNALS = { ok: 'ui_hud_ok', lost: 'ui_hud_lost', waiting: 'ui_hud_waiting' };

  function setSignal(signal) {
    const el = $('hud-signal');
    const name = SIGNALS[signal] ? signal : 'waiting';
    el.dataset.signal = name;
    el.textContent = t(SIGNALS[name]);
  }

  function showHud(m) {
    if (!m.visible) {
      $('hud').hidden = true;
      hudEnd = 0;
      return;
    }
    const info = m.info || {};
    $('hud-target').textContent = info.target || '';
    $('hud-desc').textContent = info.description || '';
    hudEnd = Date.now() + (Number(info.remaining) || 0) * 1000;
    setSignal('waiting');
    $('hud').hidden = false;
    updateTimers();
    ensureTicker();
  }

  // ----------------------------------------------------------- open / close
  function applyState(next) {
    state = next;
    renderStrip();
    renderPanel(false);
  }

  function openUi(m) {
    strings = m.strings || strings;
    applyStrings();
    form = freshForm();
    players = null;
    pending = null;
    state = m.state;
    tab = defaultTab();
    $('backdrop').hidden = false;
    renderStrip();
    renderPanel(true);
    showToast(m.toast);
    ensureTicker();
  }

  function hideUi() {
    $('backdrop').hidden = true;
    place = null;
  }

  function closeUi() {
    hideUi();
    post('close');
  }

  $('btn-close').addEventListener('click', closeUi);
  $('btn-refresh').addEventListener('click', () => {
    post('refresh');
    if (tab === 'place' && state && state.limits.selection === 'list') post('players');
  });
  $('backdrop').addEventListener('mousedown', (event) => {
    if (event.target === $('backdrop')) closeUi();
  });
  $('tabs').addEventListener('click', (event) => {
    const button = event.target.closest('button[data-tab]');
    if (button && state) showTab(button.dataset.tab);
  });
  window.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !$('backdrop').hidden) closeUi();
  });

  window.addEventListener('message', (event) => {
    const m = event.data;
    if (!m || typeof m !== 'object') return;

    switch (m.action) {
      case 'open':
        openUi(m);
        break;

      case 'state': {
        if (!m.state) break;
        const answeringPlace = pending === 'place' && m.toast;
        pending = null;
        applyState(m.state);
        showToast(m.toast);
        if (answeringPlace && m.toast.ok) {
          form = freshForm();
          showTab('mine');
        } else if (answeringPlace) {
          syncPlace();
        }
        break;
      }

      case 'players':
        players = Array.isArray(m.list) ? m.list : [];
        if (tab === 'place') fillPlayers();
        break;

      case 'close':
        hideUi();
        break;

      case 'hud':
        if (m.strings) {
          strings = m.strings;
          applyStrings();
        }
        showHud(m);
        break;

      case 'hudSignal':
        setSignal(m.signal);
        break;

      default:
        break;
    }
  });
})();
