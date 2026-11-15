// Olaz group-admin, board notes, auto-delete TTL and quick-message adapter (index.html only).
// Exposes `window.__zaloGroupAdmin`; Swift awaits its promises from `ZaloEngine+GroupAdmin.swift`.
(() => {
  'use strict';
  const NAME = '__zaloGroupAdmin';
  if (window[NAME]) return;
  if (location.pathname.split('/').pop() !== 'index.html') return;

  const diag = (s) => { try { window.webkit.messageHandlers.zlog.postMessage('[groupadmin] ' + s); } catch {} };
  const safe = (fn, d) => { try { const v = fn(); return v === undefined ? d : v; } catch { return d; } };
  const str = (v) => (typeof v === 'string' ? v : (typeof v === 'number' ? String(v) : ''));
  const bool = (v) => v === true || v === 1 || v === '1';
  const real = (o) => { try { return !!o && o.__olaz_not_a_member__ === undefined; } catch { return false; } };
  const stripG = (id) => String(id || '').replace(/^g/, '');
  const withG = (id) => { const s = String(id || ''); return s.startsWith('g') ? s : ('g' + s); };

  const QUICK_KEY = '__olaz_quick_messages_v1';
  const DEFAULT_QUICK_MESSAGES = [
    { id: 'builtin-1', shortcut: '/xin', title: 'Chào hỏi', content: 'Xin chào, mình có thể hỗ trợ gì cho bạn ạ?' },
    { id: 'builtin-2', shortcut: '/camon', title: 'Cảm ơn', content: 'Cảm ơn bạn rất nhiều!' },
    { id: 'builtin-3', shortcut: '/doi', title: 'Chờ xác nhận', content: 'Mình đã nhận được thông tin, bạn chờ mình kiểm tra chút nhé.' },
  ];

  const S = {};
  let io = null, lastResolve = 0, loadingModules = false;

  const has = (o, ...keys) => keys.every((k) => { try { return typeof o[k] === 'function'; } catch { return false; } });

  const resolve = () => {
    const req = window.__zaloRequire;
    if (!req || !window.__zaloStore || typeof window.__zaloDI !== 'function' || typeof window.__zaloEachExport !== 'function') return false;
    if (S.groups && S.friends && S.fetcher) return true;
    if (Date.now() - lastResolve < 400) return false;
    lastResolve = Date.now();

    for (const reg of window.__zaloDI(req)) {
      const i = reg && reg.instance;
      if (!real(i) || typeof i !== 'object') continue;
      try {
        if (!io && has(i, 'getFriendManagerModule', 'getGroupManagerModule')) io = i;
        if (!S.convMgr && (has(i, 'updateAutoDeleteChat') || has(i, 'getConversationInfo'))) S.convMgr = i;
      } catch {}
    }

    if (io && !loadingModules && (!S.groups || !S.friends)) {
      loadingModules = true;
      Promise.all([
        Promise.resolve(safe(() => io.getFriendManagerModule(), null)),
        Promise.resolve(safe(() => io.getGroupManagerModule(), null)),
      ]).then(([f, g]) => {
        if (f) S.friends = (f && f.default) || f;
        if (g) S.groups = (g && g.default) || g;
      }).catch((e) => diag('module load: ' + String(e))).finally(() => { loadingModules = false; });
    }

    window.__zaloEachExport(req, (ex) => {
      if (!ex || (typeof ex !== 'object' && typeof ex !== 'function') || !real(ex)) return;
      try {
        for (const o of [ex, ex.default]) {
          if (!real(o) || (typeof o !== 'object' && typeof o !== 'function')) continue;
          if (!S.fetcher && typeof o === 'object' && has(o, 'createGroupV2', 'getGroupInfoByLink')) S.fetcher = o;
          if (!S.api && has(o, 'updateAutoDeleteChat')) S.api = o;
          if (!S.info && has(o, 'getFullInfoGroupById')) S.info = o;
          if (!S.admin && has(o, 'addAdmin', 'removeAdmin') && (has(o, 'changeSettingGroup') || has(o, 'removeMember'))) S.admin = o;
          if (!S.friends && has(o, 'getProfileFriendByIdSync')) S.friends = o;
        }
      } catch {}
    });

    return !!(S.groups || S.fetcher);
  };

  const ensureReady = async () => {
    for (let i = 0; i < 8; i++) {
      if (resolve() && S.groups) return true;
      await new Promise((r) => setTimeout(r, 120));
    }
    return resolve();
  };

  const callAny = async (targets, names, ...args) => {
    for (const target of targets) {
      if (!target) continue;
      for (const name of names) {
        if (typeof target[name] === 'function') {
          try {
            return await Promise.resolve(target[name](...args));
          } catch (e) {
            diag(`${name} failed: ${String(e).slice(0, 80)}`);
            throw e;
          }
        }
      }
    }
    return null;
  };

  const storeState = () => safe(() => window.__zaloStore && window.__zaloStore.getState(), {}) || {};

  const findGroupInStore = (groupId) => {
    const st = storeState();
    const gId = withG(groupId);
    const rawId = stripG(groupId);
    const candidates = [
      safe(() => S.groups.getGroupInfoSync(gId), null),
      safe(() => S.groups.getGroupInfoSync(rawId), null),
      safe(() => st.groups && (st.groups[gId] || st.groups[rawId]), null),
      safe(() => st.conversations && (st.conversations[gId] || st.conversations[rawId]), null),
    ];
    return candidates.find((x) => x && typeof x === 'object') || {};
  };

  const profileForMember = (uid, rawMember) => {
    const id = str(uid);
    const st = storeState();
    const fromFriends = safe(() => S.friends && S.friends.getProfileFriendByIdSync(id), null);
    const fromStore = safe(() => (st.users && st.users[id]) || (st.profiles && st.profiles[id]), null);
    const m = rawMember && typeof rawMember === 'object' ? rawMember : {};
    const p = fromFriends || fromStore || {};
    const name = str(m.dName || m.zaloName || m.displayName || p.displayName || p.zaloName || p.dName) || id;
    const avatar = str(m.avatar || p.avatar || '');
    return { id, name, avatar };
  };

  const getGroupAdminInfo = async (groupId) => {
    await ensureReady();
    const gId = withG(groupId);
    const rawId = stripG(groupId);

    let info = findGroupInStore(gId);
    try {
      const targets = [S.info, S.groups, S.admin, S.fetcher];
      const fetched = await callAny(targets, ['getFullInfoGroupById'], gId)
        || await callAny(targets, ['getFullInfoGroupById'], rawId)
        || await callAny(targets, ['getGroupById'], gId);
      if (fetched && typeof fetched === 'object') {
        const inner = fetched.gridInfoMap ? (fetched.gridInfoMap[rawId] || fetched.gridInfoMap[gId]) : (fetched.data || fetched);
        if (inner && typeof inner === 'object') info = Object.assign({}, info, inner);
      }
    } catch {}

    const syncRec = safe(() => S.groups && S.groups.getGroupByIdSync(gId), null) || {};
    if (!info.creatorId && syncRec.creatorId) info = Object.assign({}, syncRec, info);
    const creatorId = str(info.creatorId || syncRec.creatorId || info.ownerId || info.creator || '');
    const adminIdsRaw = Array.isArray(info.adminIds) ? info.adminIds : (Array.isArray(info.admins) ? info.admins : []);
    const adminIds = Array.from(new Set(adminIdsRaw.map(str).filter(Boolean)));
    const adminSet = new Set(adminIds);

    const setting = (info.setting && typeof info.setting === 'object') ? info.setting : info;
    const lockSendMsg = bool(setting.lockSendMsg);
    const lockUpdateInfo = bool(setting.lockUpdateInfo || setting.lockCreatePost || setting.blockName);
    const joinAppr = bool(setting.joinAppr);
    const inviteLink = str(info.link || info.inviteLink || info.joinLink || '');
    const ttl = Number(info.ttl || info.autoDelete || info.msgTTL || 0) || 0;

    const rawMembers = Array.isArray(info.currentMems) ? info.currentMems
      : (Array.isArray(info.members) ? info.members
      : (Array.isArray(info.memVerList) ? info.memVerList
      : (Array.isArray(info.topMember) ? info.topMember : [])));

    const seen = new Set();
    const members = [];
    for (const item of rawMembers) {
      const uid = typeof item === 'string' || typeof item === 'number'
        ? str(item)
        : str(item && (item.id || item.uid || item.userId));
      if (!uid || seen.has(uid)) continue;
      seen.add(uid);
      const prof = profileForMember(uid, item);
      const role = uid === creatorId ? 'owner' : (adminSet.has(uid) ? 'admin' : 'member');
      members.push({ ...prof, role });
    }

    return {
      groupId: gId,
      creatorId,
      adminIds,
      inviteLink,
      lockSendMsg,
      lockUpdateInfo,
      joinAppr,
      ttl,
      members,
    };
  };

  const setDeputy = async (groupId, memberId, isAdmin) => {
    await ensureReady();
    const rawId = stripG(groupId);
    const uid = str(memberId);
    const methods = isAdmin
      ? ['addAdmin', 'addGroupAdmin']
      : ['removeAdmin', 'removeGroupAdmin'];
    try {
      const res = await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], methods, rawId, [uid]);
      if (res !== null) return { ok: true };
      const resSingle = await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], methods, rawId, uid);
      return { ok: resSingle !== null };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  };

  const removeMember = async (groupId, memberId, block) => {
    await ensureReady();
    const rawId = stripG(groupId);
    const uid = str(memberId);
    try {
      if (block) {
        await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], ['addGroupBlockedMember', 'blockMember', 'blockUserFromGroup'], rawId, [uid]);
      }
      const res = await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], ['removeMemberFromGroup', 'removeMember'], rawId, [uid]);
      if (res !== null) return { ok: true };
      const resSingle = await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], ['removeMemberFromGroup', 'removeMember'], rawId, uid);
      return { ok: resSingle !== null };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  };

  const updateSettings = async (groupId, settings) => {
    await ensureReady();
    const rawId = stripG(groupId);
    const payload = {
      lockSendMsg: settings && settings.lockSendMsg ? 1 : 0,
      lockCreatePost: settings && settings.lockUpdateInfo ? 1 : 0,
      lockUpdateInfo: settings && settings.lockUpdateInfo ? 1 : 0,
      joinAppr: settings && settings.joinAppr ? 1 : 0,
      blockName: settings && settings.lockUpdateInfo ? 1 : 0,
    };
    try {
      const res = await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], ['changeSettingGroup', 'updateGroupSetting'], rawId, payload);
      return { ok: res !== null };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  };

  const getOrToggleGroupLink = async (groupId, action) => {
    await ensureReady();
    const rawId = stripG(groupId);
    try {
      let res = null;
      if (action === 'enable') {
        res = await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], ['enableGroupLink', 'createGroupLink'], rawId);
      } else if (action === 'disable') {
        res = await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], ['disableGroupLink'], rawId);
      } else {
        res = await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], ['getGroupLinkDetail'], rawId);
      }
      const link = str((res && (res.link || (res.data && res.data.link))) || '').replace(/^zalo:\/\//, 'https://');
      return { ok: res !== null, link };
    } catch (e) {
      return { ok: false, link: '', error: String(e) };
    }
  };

  const getGroupNotes = async (groupId) => {
    await ensureReady();
    const gId = withG(groupId);
    const rawId = stripG(groupId);
    const st = storeState();

    let items = [];
    try {
      const res = await callAny([S.admin, S.groups, S.fetcher, S.info, S.api], ['getGroupBoardList', 'getListBoard', 'getGroupTopics', 'getNotes'], rawId);
      if (Array.isArray(res)) items = res;
      else if (res && Array.isArray(res.items)) items = res.items;
      else if (res && res.data && Array.isArray(res.data.items)) items = res.data.items;
    } catch {}

    if (!items.length) {
      const storeBoard = safe(() => (st.groupBoard && (st.groupBoard[gId] || st.groupBoard[rawId])) || (st.topics && (st.topics[gId] || st.topics[rawId])), null);
      if (Array.isArray(storeBoard)) items = storeBoard;
    }

    return items.map((n, idx) => {
      const params = typeof n.params === 'string' ? safe(() => JSON.parse(n.params), {}) : (n.params || {});
      return {
        id: str(n.id || n.topicId || n.boardId || idx),
        title: str(n.title || params.title || n.content || params.content || 'Ghi chú'),
        createdTime: Number(n.createdTime || n.createTime || n.ts || 0) || 0,
        isPinned: bool(n.pinAct || n.isPinned || n.type === 1),
      };
    });
  };

  const createGroupNote = async (groupId, title, pinAct) => {
    await ensureReady();
    const rawId = stripG(groupId);
    const cleanTitle = str(title).trim();
    if (!cleanTitle) return { ok: false, error: 'Nội dung ghi chú trống' };
    try {
      const res = await callAny(
        [S.fetcher, S.groups],
        ['createGroupTopicv2', 'createGroupNote', 'createNote', 'createGroupNoticeCmd'],
        rawId,
        cleanTitle,
        pinAct ? 2 : 0
      );
      if (res !== null) return { ok: true };
      const alt = await callAny([S.fetcher, S.groups], ['createNote'], { groupId: rawId, title: cleanTitle, pinAct: pinAct ? 2 : 0 });
      return { ok: alt !== null };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  };

  const getAutoDeleteTTL = async (convId) => {
    await ensureReady();
    const st = storeState();
    const rawId = stripG(convId);
    const conv = safe(() => (st.conversations && (st.conversations[convId] || st.conversations[rawId])), null) || findGroupInStore(convId);
    return Number((conv && (conv.ttl || conv.autoDelete || conv.msgTTL)) || 0) || 0;
  };

  const setAutoDeleteTTL = async (convId, ttlSeconds) => {
    await ensureReady();
    const isGroup = String(convId).startsWith('g');
    const rawId = stripG(convId);
    const ttl = Number(ttlSeconds) || 0;
    try {
      const res = await callAny(
        [S.convMgr, S.api, S.fetcher, S.groups],
        ['updateAutoDeleteChat', 'setAutoDeleteChat', 'updateAutoDelete'],
        rawId,
        ttl,
        isGroup ? 1 : 0
      );
      return { ok: res !== null };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  };

  const readQuickStore = () => {
    try {
      const raw = localStorage.getItem(QUICK_KEY);
      if (!raw) {
        localStorage.setItem(QUICK_KEY, JSON.stringify(DEFAULT_QUICK_MESSAGES));
        return DEFAULT_QUICK_MESSAGES.slice();
      }
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : DEFAULT_QUICK_MESSAGES.slice();
    } catch {
      return DEFAULT_QUICK_MESSAGES.slice();
    }
  };

  const writeQuickStore = (items) => {
    try { localStorage.setItem(QUICK_KEY, JSON.stringify(items)); } catch {}
  };

  const getQuickMessages = async () => {
    await ensureReady();
    const st = storeState();
    const local = readQuickStore();
    const seen = new Set(local.map((x) => x.shortcut));
    const official = safe(() => st.quickMessage && (st.quickMessage.list || st.quickMessage.items), []) || [];
    for (const q of official) {
      const sc = str(q.keyword || q.shortcut || '');
      const formatted = sc.startsWith('/') ? sc : ('/' + sc);
      if (sc && !seen.has(formatted)) {
        seen.add(formatted);
        local.push({
          id: str(q.id || formatted),
          shortcut: formatted,
          title: str(q.title || formatted),
          content: str(q.message || q.content || ''),
        });
      }
    }
    return local;
  };

  const saveQuickMessage = async (item) => {
    const shortcutRaw = str(item && item.shortcut).trim();
    const shortcut = shortcutRaw.startsWith('/') ? shortcutRaw : ('/' + shortcutRaw);
    const title = str(item && item.title).trim() || shortcut;
    const content = str(item && item.content).trim();
    if (!shortcutRaw || !content) return readQuickStore();

    const items = readQuickStore();
    const id = str(item && item.id) || ('qm-' + Date.now());
    const idx = items.findIndex((x) => x.id === id || x.shortcut.toLowerCase() === shortcut.toLowerCase());
    const entry = { id, shortcut, title, content };
    if (idx >= 0) items[idx] = entry;
    else items.unshift(entry);
    writeQuickStore(items);
    return items;
  };

  const deleteQuickMessage = async (id) => {
    const items = readQuickStore().filter((x) => x.id !== str(id));
    writeQuickStore(items);
    return items;
  };

  window[NAME] = {
    getGroupAdminInfo,
    setDeputy,
    removeMember,
    updateSettings,
    getOrToggleGroupLink,
    getGroupNotes,
    createGroupNote,
    getAutoDeleteTTL,
    setAutoDeleteTTL,
    getQuickMessages,
    saveQuickMessage,
    deleteQuickMessage,
  };
})();
