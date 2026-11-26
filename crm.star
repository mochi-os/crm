# Mochi CRM app
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: AGPL-3.0-only
# This file is part of Mochi, licensed under the GNU AGPL v3 with the
# Mochi Application Interface Exception - see license.txt and license-exception.md.

# Ceiling on an imported manifest or a whole format 2 file, checked against the
# size on disk or the archive's declared entry size before reading: far above
# any real export, low enough to refuse a decompression bomb. Core's
# mochi.archive.read refuses an entry past 64 MiB (archive_read_maximum) by
# aborting the handler, so the bound is that figure and no higher. Shared with
# the projects app.
IMPORT_MAXIMUM = 67108864


# Derive a structural id from a name. The id is a database key, a URL segment
# and, for fields, an element of the comma-separated views.fields list, so only
# letters, digits, underscore and hyphen survive; runs of anything else fold to
# one underscore. "" when nothing usable remains.
def structural_id(name):
    out = ""
    for ch in name.strip().lower().elems():
        if ch.isalpha() or ch.isdigit() or ch == "_" or ch == "-":
            out += ch
        else:
            out += "_"
    while out.find("__") >= 0:
        out = out.replace("__", "_")
    # May be "": every character folded to "_" and stripped. Callers must
    # reject that - a row with id="" can never be deleted, because every
    # delete handler guards on a truthy id.
    return out.strip("_")


# decimal(value) -> bool: non-empty ASCII decimal string. Not .isdigit(), which
# accepts Unicode digits that int() rejects.
def decimal(value):
    if not value:
        return False
    for c in value.elems():
        if c not in "0123456789":
            return False
    return True

def remote_dict(response):
	"""A remote response is usable only if it is a dict. mochi.remote.request
	returns whatever the far end encoded, so a hostile or buggy peer answering
	with a list or a string gives a value with no .get - and subscripting it
	aborts the handler part-done. Callers keep their existing falsy tests."""
	return response if type(response) == "dict" else None

# A peer's value reduced to the type the column it lands in holds, before it is
# bound. A list or tuple bound as one parameter is spread over the placeholders
# after it, and a value of the wrong type aborts the handler that indexes or
# splits it, so each field of what an owner sends is reduced on the way in.

# text(value, default="") -> value when it is a string, else default.
def text(value, default=""):
	return value if type(value) == "string" else default

# number(value, default=0) -> value as a whole number: an integer, or a float
# with no fraction (JSON numbers can arrive as either), within what a column
# binds; else default.
def number(value, default=0):
	if type(value) == "float":
		if value != value or value <= -1000000000000000 or value >= 1000000000000000 or value != int(value):
			return default
		return int(value)
	if type(value) == "int" and value > -1000000000000000 and value < 1000000000000000:
		return value
	return default

# record(value) -> value when it is a dict, else an empty one.
def record(value):
	return value if type(value) == "dict" else {}

# access_ask asks the owner of a subscribed CRM what this user may do there,
# and keeps the answer in crms.access. Answers (level, response): the level,
# "" when the owner allows nothing, or None when there is no answer, with
# response saying why (remote_error).
def access_ask(crm_id, row):
	server = row["server"] or ""
	peer = mochi.remote.peer(server) if server else None
	# The owner checks the authenticated sender, which remote.request
	# stamps with this user's identity - no payload needed.
	response = remote_dict(mochi.remote.request(crm_id, "crm", "access/check", {}, peer))
	if not response or response.get("transport") or response.get("error"):
		return None, response
	access = ""
	for level in ["design", "write", "comment", "view"]:
		if response.get(level):
			access = level
			break
	mochi.db.execute("update crms set access=?, checked=? where id=?", access, mochi.time.now(), crm_id)
	return access, response

# access_interval: how often a view of a subscribed crm asks its owner again
# for this user's level, in seconds.
access_interval = 60

# schedule_access asks the owner again after -/information has answered with
# the level it last confirmed, and tells an open page when the level moved.
def schedule_access(e):
	if e.source != "schedule":
		return
	crm_id = e.data.get("crm", "")
	if not mochi.text.valid(crm_id, "entity"):
		return
	row = mochi.db.row("select access, server from crms where id=? and owner=0", crm_id)
	if not row:
		return
	access, _ = access_ask(crm_id, row)
	if access == None or access == row["access"]:
		return
	fingerprint = mochi.entity.fingerprint(crm_id)
	if fingerprint:
		mochi.websocket.write(fingerprint, {"type": "crm/update", "crm": crm_id})

# remote_status is the status a far end's refusal is answered with here: its
# own code when that is an error status, else [code]. A 401 becomes 502: to
# every client of this server 401 means the caller's own session has ended,
# and a peer's answer says nothing about that session.
def remote_status(response, code=502):
	status = response.get("code", code)
	if type(status) == "float":
		status = int(status)
	if type(status) != "int" or status < 400 or status > 599:
		return code
	if status == 401:
		return 502
	return status

# remote_error surfaces a failed mochi.remote.request: core-authored
# transport failures (marked "transport") become a translated generic
# error with the detail kept in the server log; far-end app answers
# pass through with their label, under remote_status.
def remote_error(a, response, code=502):
	# response is None when remote_dict refused the far end's shape; that is a
	# transport-class failure as far as the caller is concerned.
	if not response:
		a.error.label(code, "errors.remote")
		return
	if response.get("transport"):
		mochi.log.info("Remote transport error: %s", response.get("error", ""))
		a.error.label(remote_status(response, code), "errors.remote")
	else:
		# The remote sends a stable label key; localise it in the caller's language.
		a.error.label(remote_status(response, code), response.get("error", "errors.remote"))

def notify(topic, object="", title="", body="", url="", event_id=""):
	mochi.service.call("notifications", "send", topic, object, title, body, url, mochi.app.label("notifications.topic." + topic.replace("/", ".")), "", "", None, event_id)

# Helper to create P2P message headers
def p2p_headers(from_id, to_id, event):
	return {
		"from": from_id,
		"to": to_id,
		"service": "crm",
		"event": event
	}

# Send a subscribe/unsubscribe to an owner whose entity may not resolve (private
# entities never list, public entries expire offline). A stored "p2p/<peer>"
# server pins the queue row to that peer so the send parks until it reconnects;
# hostname servers still route via the directory.
def registration_send(server, headers, content):
	peer = server[len("p2p/"):] if server and server.startswith("p2p/") else ""
	if peer:
		mochi.message.send.peer(peer, headers, content)
	else:
		mochi.message.send(headers, content)

# Broadcast to a CRM's subscribers through the durable log (sequence, log and
# gap detection live in core). View access is rechecked per recipient on every
# send so a revocation the app never saw (a group change) cuts the flow; a
# failing one triggers subscribers_revalidate.
# broadcast_event(crm_id, event, data, exclude=None, handle=None) -> whether a
# subscriber failed the view check. Within a transaction (handle) the
# subscribers are read through it, and dropping one that failed is left to the
# caller once it commits (events_commit), since that writes and sends. There
# the event goes out when the transaction commits, where core can send it then,
# so a change rolled back after a refusal sends none of its events; an older
# core sends it at once.
def broadcast_event(crm_id, event, data, exclude=None, handle=None):
	if not crm_id:
		return False
	members, stale = recipients(crm_id, handle)
	if members == None:
		return False
	ids = [m["id"] for m in members]
	if handle and hasattr(handle, "broadcast"):
		handle.broadcast(crm_id, crm_id, ids, "crm", event, data, exclude or "")
	else:
		mochi.broadcast.send(crm_id, crm_id, ids, "crm", event, data, exclude or "")
	return stale

# recipients(crm_id, handle=None) -> (members, stale): who a CRM this user owns
# sends to, as {id, name} rows - every subscriber that still passes the view
# check, the owner's own identity left out - and whether a row failed it. Every
# fan-out goes through here: broadcast_event, the snapshot an import sends and
# the mention sender. Access comes through groups and wildcards, so a row can be
# stale without this app having been told; one that fails is dropped
# (subscribers_revalidate), here, or within a transaction (handle) by the
# caller once it commits (events_commit), since that writes and sends. A
# replica's roster (event_member_add) is the owner's to send to: for a CRM this
# user does not own the answer is None, and nothing is sent.
def recipients(crm_id, handle=None):
	database = handle or mochi.db
	if not database.exists("select 1 from crms where id=? and owner=1", crm_id):
		return None, False
	owner = get_owner_identity(crm_id, handle)
	members = []
	stale = False
	for s in database.rows("select id, name from subscribers where crm=?", crm_id) or []:
		if s["id"] == owner:
			continue
		if check_crm_access(s["id"], crm_id, "view"):
			members.append({"id": s["id"], "name": s["name"]})
		else:
			stale = True
	if stale and not handle:
		subscribers_revalidate(crm_id)
	return members, stale

# Drop every subscriber that no longer passes the view check (access comes via
# groups and wildcards, so a revoked subject does not map to rows) and send each
# an access/revoke so its server purges the replica, then tell the members who
# remain (member/remove). The owner's identity is always kept: it anchors
# get_owner_identity. What a departed member did stays in the activity log.
def subscribers_revalidate(crm_id):
	if not mochi.db.exists("select 1 from crms where id=? and owner=1", crm_id):
		return
	owner = get_owner_identity(crm_id)
	removed = []
	for s in mochi.db.rows("select id from subscribers where crm=?", crm_id) or []:
		if s["id"] == owner or check_crm_access(s["id"], crm_id, "view"):
			continue
		mochi.message.send(p2p_headers(crm_id, s["id"], "access/revoke"), {})
		subscriber_remove(crm_id, s["id"])
		removed.append(s["id"])
	if removed:
		row_set("crms", "id=?", [crm_id], {"updated": mochi.time.now()})
		for id in removed:
			broadcast_event(crm_id, "member/remove", {"crm": crm_id, "id": id})
		fingerprint = mochi.entity.fingerprint(crm_id)
		if fingerprint:
			mochi.websocket.write(fingerprint, {"type": "crm/update", "crm": crm_id})

# subscriber_remove(crm_id, id): take a member off a CRM this user owns - their
# watcher rows, their subscriber row and core's replay record - wherever a
# subscriber row goes. Dropping them from the fan-out list stops new events but
# not replay: core keeps a subscription record so a lagging subscriber can
# resync, and it lives on the log's own clock. Without its removal a member who
# unsubscribed, or whose access was withdrawn, could still pull events created
# after they left. Their activity stays: it is the record of what they did.
def subscriber_remove(crm_id, id):
	row_remove("watchers", "user=? and object in (select id from objects where crm=?)", [id, crm_id])
	row_remove("subscribers", "crm=? and id=?", [crm_id, id])
	mochi.broadcast.subscriber.remove(crm_id, id)

# subscriber_drop(entity): drop a subscriber core gave up on from every CRM this
# user owns that has one, except where that row is the CRM owner's own, which
# subscribers_revalidate keeps too, and tell the members who remain. A
# replica's roster is the owner's to change.
def subscriber_drop(entity):
	for row in mochi.db.rows("select s.crm as crm from subscribers s join crms c on c.id=s.crm where s.id=? and c.owner=1", entity) or []:
		if get_owner_identity(row["crm"]) == entity:
			continue
		subscriber_remove(row["crm"], entity)
		broadcast_event(row["crm"], "member/remove", {"crm": row["crm"], "id": entity})

# error_message_timeout: core calls this when a fan-out to a subscriber aged
# out undelivered. Remove them only when the directory shows no host left
# (locations == 0) - definitely gone, not a transient outage or a server
# migration in progress.
def error_message_timeout(e):
	if e.detail.get("locations", 1) != 0:
		return
	subscriber_drop(e.entity)

# error_subscriber_unreachable: core suspended this subscriber - every
# delivery across the whole evict window failed with no contradicting
# success - and asks us to drop them so fan-out stops paying for a dead
# host. If they return, they re-subscribe. Core asks from inside the broadcast
# that found them suspended, which a change sends before its transaction
# commits (events_commit), so the drop, which writes, is left to a scheduled
# task: written here, it would wait on the lock that transaction holds until it
# timed out.
def error_subscriber_unreachable(e):
	mochi.schedule.after("schedule_drop", {"entity": e.entity}, 0)

# schedule_drop(e): the drop error_subscriber_unreachable put off.
def schedule_drop(e):
	if e.source != "schedule":
		return
	entity = e.data.get("entity", "")
	if not mochi.text.valid(entity, "entity"):
		return
	subscriber_drop(entity)
# error_broadcast_gap: core calls this when an unfillable broadcast gap was
# skipped and events were permanently lost. broadcast/resync can't replay a
# pruned gap, so pull a fresh full snapshot.
def error_broadcast_gap(e):
	request_resync(e.entity)

# request_resync pulls a fresh schema dump from the owner when an inbound event
# references an object the subscriber has not seen (lost or reordered delivery).
# insert_schema applies it idempotently; throttled to once a minute.

# idle_resync_age: how long without applying any broadcast from a subscribed
# CRM before the next view re-subscribes (the owner may have pruned us after a
# long idle). Matches core's broadcast_log_age.
idle_resync_age = 7 * 86400

def request_resync(crm_id, repeat=False, budget=None, force=False):
	"""Returns True iff every part of a fresh schema was fetched and applied
	within this call. A pull that runs out of time is continued by
	schedule_schema; one that fails waits for the next resync. repeat marks
	the fresh pull a pull that skipped late rows asked for (schedule_resync).
	budget is the seconds the call may spend on parts after the first,
	SCHEMA_TIME when None (it is defined after this). force, for a resync the
	user asks for, starts it at once whatever is under way."""
	row = mochi.db.row("select server, synced from crms where id=? and owner=0", crm_id)
	if not row:
		return False
	now = mochi.time.now()
	# A pull under way, its continuation pending, finishes first: one started
	# beside it would replace it and take the CRM again from the start, and
	# with steady events nothing would ever be pruned. One within the last
	# minute stands. What asked for this one - a gap, an event naming what is
	# not held - may need what they read before it, so it runs after them
	# rather than not at all.
	pending = schema_continuing(crm_id)
	if not force and (pending or (row["synced"] and now - row["synced"] < 60)):
		resync_defer(crm_id, repeat, 61 if pending else 61 - (now - row["synced"]))
		return False
	row_set("crms", "id=?", [crm_id], {"synced": now})
	server = row["server"] or ""
	peer = ""
	if server:
		peer = mochi.remote.peer(server)
	# What the replica holds before the first part is read: only those rows may
	# be pruned once the pull completes. The pull's own rows go in first, so a
	# live event landing after the read cancels its prune (schema_cancel).
	pull = schema_begin(crm_id, True, repeat)
	held = schema_holdings(crm_id)
	schema = schema_fetch(crm_id, peer, SCHEMA_START)
	if not schema or schema.get("error"):
		schema_end(crm_id, pull)
		return False
	schema_claim(crm_id, pull)
	if not insert_schema(crm_id, schema, peer, now, held, 0, SCHEMA_TIME if budget == None else budget, pull):
		return False
	schema_completed(crm_id)
	return True

# schema_continuing(crm_id) -> bool: whether a continuation of the CRM's own
# pull is pending. One of a pull replaced since, or of a subscription dropped,
# does nothing when it comes due, and holds no resync off.
def schema_continuing(crm_id):
	for scheduled in mochi.schedule.list():
		if scheduled.event == "schedule_schema" and scheduled.data.get("crm") == crm_id and schema_current(crm_id, schema_pull(scheduled.data.get("pull"))):
			return True
	return False

# schema_pending(crm_id, event) -> bool: whether a scheduled event of the
# CRM is pending.
def schema_pending(crm_id, event):
	for scheduled in mochi.schedule.list():
		if scheduled.event == event and scheduled.data.get("crm") == crm_id:
			return True
	return False

# resync_defer(crm_id, repeat, wait) puts off a resync request_resync could not
# start for wait seconds, once a CRM however often it is asked for
# meanwhile.
def resync_defer(crm_id, repeat, wait):
	if not schema_pending(crm_id, "schedule_resync"):
		mochi.schedule.after("schedule_resync", {"crm": crm_id, "repeat": repeat}, wait)

# schedule_resync(e): the fresh pull a pull that skipped late rows asked for,
# once request_resync's throttle has passed, which asks for none after it; or a
# resync put off (resync_defer), put off again while a pull still runs.
def schedule_resync(e):
	if e.source != "schedule":
		return
	crm_id = e.data.get("crm", "")
	if not mochi.text.valid(crm_id, "entity"):
		return
	request_resync(crm_id, e.data.get("repeat", True) != False)

# Re-subscribe to a CRM idle longer than idle_resync_age: the owner's
# event_subscribe is idempotent and pushes catch-up. touch() stamps the timer so
# a quiet CRM re-subscribes once per window.
def maybe_resubscribe(a, crm_id):
	user_id = a.user.identity.id if a.user else None
	if not user_id:
		return
	row = mochi.db.row("select server from crms where id=? and owner=0", crm_id)
	if not row:
		return
	if mochi.time.now() - mochi.broadcast.seen(crm_id) <= idle_resync_age:
		return
	registration_send(row["server"], p2p_headers(user_id, crm_id, "subscribe"), {"name": a.user.identity.name})
	mochi.broadcast.touch(crm_id)

# --- Fractional-index rank keys (#53) ---------------------------------------
# Canonical fractional indexing (Evan Wallace's algorithm): a key is an integer
# header (length-prefixed magnitude) + a fractional part. Append/prepend
# increment/decrement the header (base-62 counting -> logarithmic); only a true
# between-insert bisects the fraction. ASCII-sorted alphabets, so SQLite BINARY
# order == key order; non-numeric text in the INTEGER-affinity `rank` column
# stays text, so no column rebuild. Only the owner mints keys, under the
# database's write lock (rank_transaction). A move names the object it was
# dropped beside and takes a key in the gap next to that object's across the
# whole CRM, so no other object holds it; every object that shares the
# neighbour's key is first given one of its own. The keys a move writes go to
# subscribers in one object/ranks event, applied as sent.
RANK_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
RANK_HEADERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
RANK_SMALLEST = "A00000000000000000000000000"  # 'A' + 26 zeros: smallest integer header
RANK_LENGTH = 1024  # the longest key a copy takes from its owner
# A move that writes a key longer than RANK_SPREAD spreads its neighbours' keys
# again (rank_respread); one object/ranks event carries at most RANK_CHUNK keys.
RANK_SPREAD = 96
RANK_CHUNK = 200

def rank_int_length(head):
	i = RANK_HEADERS.index(head)
	return (i - 26) + 2 if i >= 26 else (25 - i) + 2

def rank_int_part(key):
	return key[:rank_int_length(key[0])]

def rank_increment(x):
	# Next integer after header+digits x, or None on overflow.
	head = x[0]
	digits = [x[i] for i in range(1, len(x))]
	carry = True
	for i in range(len(digits) - 1, -1, -1):
		if not carry:
			break
		d = RANK_ALPHABET.index(digits[i]) + 1
		if d == 62:
			digits[i] = RANK_ALPHABET[0]
		else:
			digits[i] = RANK_ALPHABET[d]
			carry = False
	if not carry:
		return head + "".join(digits)
	if head == "Z":
		return "a" + RANK_ALPHABET[0]
	if head == "z":
		return None
	h = RANK_HEADERS[RANK_HEADERS.index(head) + 1]
	if RANK_HEADERS.index(h) >= 26:
		digits.append(RANK_ALPHABET[0])
	else:
		digits.pop()
	return h + "".join(digits)

def rank_decrement(x):
	# Previous integer before header+digits x, or None on underflow.
	head = x[0]
	digits = [x[i] for i in range(1, len(x))]
	borrow = True
	for i in range(len(digits) - 1, -1, -1):
		if not borrow:
			break
		d = RANK_ALPHABET.index(digits[i]) - 1
		if d == -1:
			digits[i] = RANK_ALPHABET[61]
		else:
			digits[i] = RANK_ALPHABET[d]
			borrow = False
	if not borrow:
		return head + "".join(digits)
	if head == "a":
		return "Z" + RANK_ALPHABET[61]
	if head == "A":
		return None
	h = RANK_HEADERS[RANK_HEADERS.index(head) - 1]
	if RANK_HEADERS.index(h) < 26:
		digits.append(RANK_ALPHABET[61])
	else:
		digits.pop()
	return h + "".join(digits)

def rank_midpoint(a, b):
	# A fractional string strictly between a and b (b None = open upper bound).
	zero = RANK_ALPHABET[0]
	if b != None and len(b) > 0:
		n = 0
		for _ in range(4096):
			ca = a[n] if n < len(a) else zero
			if ca != b[n]:
				break
			n += 1
			if n >= len(b):
				break
		if n > 0:
			return b[:n] + rank_midpoint(a[n:], b[n:])
	da = RANK_ALPHABET.index(a[0]) if len(a) > 0 else 0
	db = RANK_ALPHABET.index(b[0]) if (b != None and len(b) > 0) else 62
	if db - da > 1:
		return RANK_ALPHABET[(da + db) // 2]
	if b != None and len(b) > 1:
		return b[:1]
	return RANK_ALPHABET[da] + rank_midpoint(a[1:] if len(a) > 0 else "", None)

def rank_canonical(key):
	# True if key is a valid canonical fractional-index key, vs a legacy INTEGER
	# rank from before #53 (read from the DB as a Starlark int, or as a numeric
	# string). TRANSITIONAL — remove with the tolerance guards in rank_between
	# once every host has migrated.
	if key == None or type(key) != "string" or len(key) == 0:
		return False
	if RANK_HEADERS.find(key[0]) < 0:
		return False
	return rank_int_length(key[0]) <= len(key)

def rank_between(a, b):
	# A key strictly between a and b (None = before-all / after-all). A legacy
	# integer rank cannot be placed on the canonical scale, so it is treated as an
	# open boundary; drop these two guards and rank_canonical once every rank is
	# canonical.
	if not rank_canonical(a):
		a = None
	if not rank_canonical(b):
		b = None
	if a == None and b == None:
		return "a" + RANK_ALPHABET[0]
	if a == None:
		ib = rank_int_part(b)
		fb = b[len(ib):]
		if ib == RANK_SMALLEST:
			return ib + rank_midpoint("", fb)
		if ib < b:
			return ib
		return rank_decrement(ib)
	if b == None:
		ia = rank_int_part(a)
		fa = a[len(ia):]
		i = rank_increment(ia)
		return (ia + rank_midpoint(fa, None)) if i == None else i
	ia = rank_int_part(a)
	fa = a[len(ia):]
	ib = rank_int_part(b)
	fb = b[len(ib):]
	if ia == ib:
		return ia + rank_midpoint(fa, fb)
	i = rank_increment(ia)
	if i != None and i < b:
		return i
	return ia + rank_midpoint(fa, None)

# rank_spread(a, b, n) -> n keys strictly between a and b (None = open), in
# order. Between two keys they are bisected, the middle one first and each half
# the same way, so their length grows with the log of n, not with n; toward an
# open end each steps on from the last, as an append does. Wallace's
# generateNKeysBetween, mirrored by rankSpread in lib/web.
def rank_spread(a, b, n):
	if n <= 0:
		return []
	if n == 1:
		return [rank_between(a, b)]
	if b == None:
		keys = [rank_between(a, None)]
		for _ in range(n - 1):
			keys.append(rank_between(keys[-1], None))
		return keys
	if a == None:
		keys = [rank_between(None, b)]
		for _ in range(n - 1):
			keys.append(rank_between(None, keys[-1]))
		return list(reversed(keys))
	middle = n // 2
	key = rank_between(a, b)
	return rank_spread(a, key, middle) + [key] + rank_spread(key, b, n - middle - 1)

# rank_valid(key) -> whether key is one a copy takes from its owner: canonical,
# over the alphabet and no longer than RANK_LENGTH.
def rank_valid(key):
	return rank_canonical(key) and len(key) <= RANK_LENGTH and key.lstrip(RANK_ALPHABET) == ""

# rank_copy(value) -> the key a copy stores for an object its owner sends whole
# (a create, its answer, a sync): a valid key as it is, and anything else as an
# integer from before keys were canonical, 0 when it is not one.
def rank_copy(value):
	return value if rank_valid(value) else safe_int(value)

# rank_transaction(object_id) -> an open transaction holding the database's
# write lock, which a key is minted under: two moves, or a move and a create,
# that read one gap at once would each mint the key in it. Its first statement
# writes, so a second waits its turn there; one that read first could not write
# once another had, and would fail. Every read and write of the mint goes
# through it, since a statement outside it would wait on the lock it holds.
def rank_transaction(object_id):
	handle = mochi.db.transaction()
	handle.execute("update objects set rank=rank where id=?", object_id)
	return handle

# version_take(versions, object_id, handle) -> the version object_id takes in the
# change whose transaction handle is. An owner counts in an object's version
# every change it makes to the object - its values, parent, class and key, a key
# it unties or spreads again included - raised once in the change's own
# transaction, and every event and answer that writes the object carries it, so
# a copy orders two changes made in one second, and keeps a later key over an
# earlier answer's. versions holds what the change has taken, {id: version}, so
# each object it changes is raised once however many of its rows it writes.
def version_take(versions, object_id, handle):
	if object_id not in versions:
		handle.execute("update objects set version=version+1 where id=?", object_id)
		row = handle.row("select version from objects where id=?", object_id)
		versions[object_id] = row["version"] if row else 0
	return versions[object_id]

def rank_neighbours(crm_id, object_id, scope, pos, handle):
	# The objects either side of 1-based position `pos` within the move's scope,
	# as (after, before) ids, for a client that sends a position rather than the
	# neighbour it dropped beside. They are counted in the scope rank_member
	# holds a neighbour to - the column, the lane and the parent alike - since a
	# neighbour counted elsewhere would be refused there, and the move would do
	# nothing.
	joins, conditions, joined, conditioned = rank_scope(scope)
	others = handle.rows("select o.id as id from objects o" + joins + " where o.crm=? and o.id!=?" + conditions + " order by o.rank asc, o.created desc, o.id desc", *(joined + [crm_id, object_id] + conditioned)) or []
	n = len(others)
	if pos < 1:
		pos = 1
	if pos > n + 1:
		pos = n + 1
	after = others[pos - 2]["id"] if pos >= 2 else None
	before = others[pos - 1]["id"] if (pos - 1) < n else None
	return after, before

def rank_beside(crm_id, exclude_id, key, after, handle):
	# A key directly after (or before) `key` in the whole CRM's order: between it
	# and the next key any object holds, so no other object, in any column or
	# parent, can hold the key minted. A key minted between two neighbours of one
	# column alone may be one a card elsewhere holds, and two cards with one key
	# have no place between them.
	if after:
		row = handle.row("select min(rank) as r from objects where crm=? and id!=? and rank>?", crm_id, exclude_id, key)
		return rank_between(key, row["r"] if row else None)
	row = handle.row("select max(rank) as r from objects where crm=? and id!=? and rank<?", crm_id, exclude_id, key)
	return rank_between(row["r"] if row else None, key)

def rank_untie(crm_id, exclude_id, anchor, ranks, versions, handle):
	# The anchor's key, after giving each object that shares it one of its own,
	# spread through the gap around it in the order lists show them. Each new key
	# is appended to ranks as {id, rank, version}, the object's version raised
	# for it (version_take). None if the anchor is not in the CRM,
	# or holds a key from before keys were canonical: such a key has no place on
	# the scale, and one minted beside it would sort after every such key and
	# could be one another object holds.
	row = handle.row("select rank from objects where id=? and crm=?", anchor, crm_id)
	if not row or not rank_canonical(row["rank"]):
		return None
	key = row["rank"]
	tied = handle.rows("select id from objects where crm=? and id!=? and rank=? order by created desc, id desc", crm_id, exclude_id, key) or []
	if len(tied) < 2:
		return key
	low = handle.row("select max(rank) as r from objects where crm=? and id!=? and rank<?", crm_id, exclude_id, key)
	high = handle.row("select min(rank) as r from objects where crm=? and id!=? and rank>?", crm_id, exclude_id, key)
	keys = rank_spread(low["r"] if low else None, high["r"] if high else None, len(tied))
	for t, k in zip(tied, keys):
		handle.execute("update objects set rank=? where id=?", k, t["id"])
		ranks.append({"id": t["id"], "rank": k, "version": version_take(versions, t["id"], handle)})
		if t["id"] == anchor:
			key = k
	return key

def move_place_check(object_id, after, before):
	# The error a move's neighbours give, or None: each one sent is the id of
	# another object. Whether it is still in the CRM is move_rank's to judge,
	# since one deleted since the board was read leaves the other.
	for anchor in [after, before]:
		if anchor == None or anchor == "":
			continue
		if type(anchor) != "string" or anchor == object_id:
			return {"key": "errors.invalid_value"}
	return None

# rank_scope(scope) -> (joins, conditions, join arguments, condition arguments):
# the SQL that keeps, of the objects o of a statement, those in a move's scope
# (see move_rank). The column or the lane for no value holds, beside the
# objects with none, those whose value no option of the field has for the
# moved object's class (scope's class), as clients draw them there: a deleted
# option's, or another class's.
def rank_scope(scope):
	joins = ""
	conditions = ""
	joined = []
	conditioned = []
	for field, value, alias in [(scope["field"], scope["value"], "c"), (scope["lane"], scope["row"], "l")]:
		if not field:
			continue
		joins += " left join \"values\" " + alias + " on " + alias + ".object=o.id and " + alias + ".field=?"
		joined.append(field)
		if value:
			conditions += " and coalesce(" + alias + ".value, '')=?"
			conditioned.append(value)
		else:
			conditions += (" and (coalesce(" + alias + ".value, '')='' or (exists (select 1 from fields f where f.crm=o.crm and f.class=? and f.id=? and f.fieldtype='enumerated')"
				+ " and not exists (select 1 from options n where n.crm=o.crm and n.class=? and n.field=? and n.id=" + alias + ".value)))")
			conditioned += [scope["class"], field, scope["class"], field]
	if scope["parent"] != None:
		conditions += " and o.parent=?"
		conditioned.append(scope["parent"])
	return joins, conditions, joined, conditioned

# rank_member(crm_id, anchor, scope, handle) -> whether anchor is an object of
# the CRM in the move's scope: a neighbour moved to another column, lane or
# parent since the board was read is no neighbour there.
def rank_member(crm_id, anchor, scope, handle):
	joins, conditions, joined, conditioned = rank_scope(scope)
	return handle.exists("select 1 from objects o" + joins + " where o.id=? and o.crm=?" + conditions, *(joined + [anchor, crm_id] + conditioned))

# rank_edge(crm_id, object_id, key, scope, after, handle) -> a key past the CRM's
# last (after) or below its first, when the anchor holding key is the last or
# first object of the move's scope; else None. A drop at a column's end beside
# its last card would otherwise take the gap to the next key in the whole CRM,
# usually another column's, and each such drop halves it, so a column appended
# to grows its keys by a character every six or so drops. None too when the
# CRM's end holds a key no owner mints, which has no place on the scale.
def rank_edge(crm_id, object_id, key, scope, after, handle):
	joins, conditions, joined, conditioned = rank_scope(scope)
	beyond = " and o.rank>?" if after else " and o.rank<?"
	if handle.exists("select 1 from objects o" + joins + " where o.crm=? and o.id!=?" + beyond + conditions, *(joined + [crm_id, object_id, key] + conditioned)):
		return None
	if after:
		row = handle.row("select max(rank) as r from objects where crm=? and id!=?", crm_id, object_id)
	else:
		row = handle.row("select min(rank) as r from objects where crm=? and id!=? and typeof(rank)='text'", crm_id, object_id)
	edge = row["r"] if row else None
	if not rank_valid(edge):
		return None
	return rank_between(edge, None) if after else rank_between(None, edge)

# rank_bound(key) -> whether a spread of keys may stand beside key: none, an
# integer from before keys were canonical, a key a copy takes, or text that
# sorts below or above every such key. Anything else, a key past RANK_LENGTH or
# off the alphabet, cannot be bisected, and is spread over itself.
def rank_bound(key):
	if key == None or type(key) != "string":
		return True
	return rank_valid(key) or key < "A" or key >= "{"

# rank_crowded(key) -> whether a spread must reach past key, the first key beyond
# one side of its window: one that cannot be bisected (rank_bound), or one past
# half of RANK_SPREAD, which lies among the long keys the drops grew there, so a
# spread stopping at it would be as long.
def rank_crowded(key):
	if key == None or type(key) != "string":
		return False
	return not rank_bound(key) or len(key) > RANK_SPREAD // 2

# rank_respread(crm_id, ranks, versions, handle): when a key in ranks, the keys
# a move wrote as {id, rank, version}, is past RANK_SPREAD, give the objects
# around it new keys spread evenly through a wider gap, in the order lists show
# them (rank asc, created desc, id desc), so none is past half of RANK_SPREAD.
# Repeated drops into one gap halve it each time, and a key there grows by a
# character every six or so; past RANK_LENGTH a copy takes none, and would show
# the object first. Each long key is spread around on its own, since a move's
# keys may lie far apart - a neighbour's untie beside one, the moved object at
# the CRM's end - and the objects between them need no new keys. The objects
# taken are those holding the key and eight either side, a side doubling while
# the key just past it is crowded (rank_crowded), so a cluster of long keys on
# one side does not widen the other, and both doubling while the spread is
# still too long; a side stops at the CRM's end. Each key rewritten is added to
# ranks, or replaces the one there for its object, with the object's version
# raised for it (version_take). Runs in the move's transaction
# (rank_transaction).
def rank_respread(crm_id, ranks, versions, handle):
	limit = RANK_SPREAD // 2
	for key in sorted([r["rank"] for r in ranks if type(r["rank"]) == "string" and len(r["rank"]) > RANK_SPREAD]):
		# An earlier key's spread may have taken this one too.
		middle = handle.rows("select id, rank from objects where crm=? and rank=? order by created desc, id desc", crm_id, key) or []
		if not middle:
			continue
		lower = 8
		upper = 8
		window = None
		spread = None
		for _ in range(64):
			below = handle.rows("select id, rank from objects where crm=? and rank<? order by rank desc, created asc, id asc limit ?", crm_id, key, lower + 1) or []
			above = handle.rows("select id, rank from objects where crm=? and rank>? order by rank asc, created desc, id desc limit ?", crm_id, key, upper + 1) or []
			low = below[lower]["rank"] if len(below) > lower else None
			high = above[upper]["rank"] if len(above) > upper else None
			widen = rank_crowded(low)
			deepen = rank_crowded(high)
			if not widen and not deepen:
				window = list(reversed(below[:lower])) + list(middle) + list(above[:upper])
				spread = rank_spread(low if rank_valid(low) else None, high if rank_valid(high) else None, len(window))
				if (low == None and high == None) or max([len(k) for k in spread]) <= limit:
					break
				widen = low != None
				deepen = high != None
			if widen:
				lower *= 2
			if deepen:
				upper *= 2
		if not window:
			continue
		written = {}
		for i, r in enumerate(ranks):
			written[r["id"]] = i
		for o, k in zip(window, spread):
			if o["rank"] == k:
				continue
			handle.execute("update objects set rank=? where id=?", k, o["id"])
			version = version_take(versions, o["id"], handle)
			if o["id"] in written:
				ranks[written[o["id"]]]["rank"] = k
				ranks[written[o["id"]]]["version"] = version
			else:
				written[o["id"]] = len(ranks)
				ranks.append({"id": o["id"], "rank": k, "version": version})

# rank_broadcast(crm_id, ranks, now, user_id, events): add to events, for
# events_commit, the object/ranks events that tell subscribers the keys a move
# wrote, at most RANK_CHUNK in each, with the owner's time for the move. Each
# entry carries its object's version, and a copy holding a later change of the
# object skips it.
def rank_broadcast(crm_id, ranks, now, user_id, events):
	for start in range(0, len(ranks), RANK_CHUNK):
		events.append({"event": "object/ranks", "data": {
			"crm": crm_id, "ranks": ranks[start:start + RANK_CHUNK], "user": user_id, "updated": now,
		}})

# move_rank(crm_id, object_id, scope, place, moved, versions, handle) -> every
# key the move writes, as {id, rank, version} rows: object_id's, any a
# neighbour's tie took and any spread again around them, each with its
# object's version for the move (version_take). scope is where the move puts
# the object, as {"field", "value", "lane", "row", "parent", "class"}: the
# board's field and the value it takes there, its lane field and that value,
# each "" where the move names none, the parent whose children it goes among,
# None for none, and the object's class, whose options say which values the
# column or lane for no value holds (rank_scope). place holds after and
# before, the objects it was dropped directly
# after and before, and the key goes beside the first of them still in that
# scope: one deleted or moved elsewhere since the board was read leaves the
# other. Beside the scope's last object, or above its first, it goes past the
# CRM's last key or below its first (rank_edge), but only when the drop named
# no neighbour on the far side: a list that draws other scopes' objects
# between its own, a filtered or grouped one, sends both, and the object goes
# between them. A client that predates them sends rank, a 1-based position
# within scope. With no neighbour, a move to another column (moved) goes to
# the end, and anything else keeps its key. Every read and write is the move's
# transaction's (handle).
def move_rank(crm_id, object_id, scope, place, moved, versions, handle):
	after = place.get("after") or None
	before = place.get("before") or None
	rank = place.get("rank")
	if after == None and before == None and rank != None:
		after, before = rank_neighbours(crm_id, object_id, scope, int(rank), handle)
		if after == None and before == None:
			moved = True
	ranks = []
	key = None
	for anchor, beside, far in [(after, True, before), (before, False, after)]:
		if anchor == None or not rank_member(crm_id, anchor, scope, handle):
			continue
		found = rank_untie(crm_id, object_id, anchor, ranks, versions, handle)
		if found != None:
			key = (rank_edge(crm_id, object_id, found, scope, beside, handle) if far == None else None) or rank_beside(crm_id, object_id, found, beside, handle)
			break
	if key == None and moved:
		key = rank_after_all(crm_id, object_id, handle)
	if key != None:
		handle.execute("update objects set rank=? where id=?", key, object_id)
		ranks.append({"id": object_id, "rank": key, "version": version_take(versions, object_id, handle)})
	rank_respread(crm_id, ranks, versions, handle)
	return ranks

def rank_after_all(crm_id, exclude_id, handle):
	# A key greater than every key in the CRM (excluding the row being moved).
	# Anchored on the crm-wide max, not the scope's: a per-scope max re-mints keys
	# that cards moved elsewhere still hold. crm-max >= any scope's last, so the
	# key still sorts last in the target scope.
	if exclude_id != None:
		row = handle.row("select max(rank) as r from objects where crm=? and id!=?", crm_id, exclude_id)
	else:
		row = handle.row("select max(rank) as r from objects where crm=?", crm_id)
	return rank_between(row["r"] if (row and row["r"]) else None, None)

def database_upgrade(version):
	if version == 2:
		# Drop the broadcast tables left in the app data DB when broadcast state moved
		# to the per-app system DB - stale copies mislead diagnosis.
		for table in ["sequence", "log", "acknowledged", "received"]:
			mochi.db.execute("drop table if exists " + table)
	if version == 3 or version == 4 or version == 5:
		# Attachments move into this database, owned by the shared library: create the
		# table and copy rows out of core's store (bridge or export file). Each of
		# versions 3 to 5 runs the step; idempotent.
		attachment_schema_create()
		attachment_migrate()
	if version == 6:
		# links is filtered by crm on export, reconcile and delete; activity by
		# user on the per-user lists; values by field on rename and delete.
		mochi.db.execute("create index if not exists links_crm on links(crm)")
		mochi.db.execute("create index if not exists activity_user on activity(user)")
		mochi.db.execute("create index if not exists values_field on \"values\"(field)")
	if version == 7:
		# The access level the owner last confirmed, so -/information answers
		# without asking first and a replica stays readable while the owner is
		# unreachable. Idempotent via the column list.
		if "access" not in [c["name"] for c in mochi.db.table("crms")]:
			mochi.db.execute("alter table crms add column access text not null default ''")
	if version == 8:
		# When the owner was last asked for this user's level, so a view asks
		# again at most once a minute (schedule_access). Idempotent via the
		# column list.
		if "checked" not in [c["name"] for c in mochi.db.table("crms")]:
			mochi.db.execute("alter table crms add column checked integer not null default 0")
	if version == 9:
		# The chunks of an owner's sync batch a subscriber holds, so it marks a
		# replica populated only once every chunk of one sync has landed.
		mochi.db.execute("create table if not exists chunks ( crm text not null, sync text not null, chunk integer not null, created integer not null default 0, primary key ( crm, sync, chunk ) )")
	if version == 10:
		# What a resync that runs past its own call may still prune: the rows
		# the replica held before the pull began that no part has named yet, so
		# the continuation that takes its last part reconciles deletions.
		mochi.db.execute("create table if not exists holdings ( crm text not null, pull text not null, list text not null, key text not null, primary key ( crm, pull, list, key ) )")
	if version == 11:
		# Attachment rows name the kind of thing they belong to; the rows filed
		# on a comment's id become the comment's. An id an object holds too came
		# from a peer's choice, as did the comment's author and any remote row's
		# creator, so its rows stay the object's.
		attachment_schema_kind()
		mochi.db.execute("update attachments set kind='comment' where object in (select id from comments) and object not in (select id from objects)")
	if version == 12:
		# A level is a ceiling (access_ceiling). Each subject an earlier
		# access/set or create gave one allow is re-set at the highest level it
		# is allowed, so a group's, "+"'s or "*"'s broader grant no longer
		# reaches it.
		for row in mochi.db.rows("select id from crms where owner=1") or []:
			access_rewrite("crm/" + row["id"])
	if version == 13:
		# The key index leads with the CRM: a move reads the gap beside a key
		# within one CRM, and the list reads one CRM in key order. With the rank
		# alone, each read scanned the CRM's rows.
		mochi.db.execute("drop index if exists objects_rank")
		mochi.db.execute("create index if not exists objects_rank on objects(crm, rank)")
	if version == 14:
		# Each object counts the changes its owner makes to it (version_take),
		# which every event and answer that writes the object carries, so a
		# copy orders two changes made in one second and a key re-spread
		# after an answer was read. Rows from before start at none.
		if "version" not in [c["name"] for c in mochi.db.table("objects")]:
			mochi.db.execute("alter table objects add column version integer not null default 0")
		# A group's "No access" is one "*" deny, which core takes as a veto over
		# every group's grant on the CRM (access_ceiling).
		for row in mochi.db.rows("select id from crms where owner=1") or []:
			access_veto("crm/" + row["id"])
	if version == 15:
		# When each subscriber was last sent the whole CRM, so a subscribe
		# repeated within snapshot_seconds is answered with nothing
		# (event_subscribe). Rows from before start at never. Idempotent via the
		# column list.
		if "sent" not in [c["name"] for c in mochi.db.table("subscribers")]:
			mochi.db.execute("alter table subscribers add column sent integer not null default 0")

# Create database with all 18 tables
def database_create():
	# 1. crms - the container, a Mochi entity
	mochi.db.execute("""create table if not exists crms (
		id text primary key,
		name text not null,
		description text not null default '',
		owner integer not null default 1,
		server text not null default '',
		fingerprint text not null default '',
		template text not null default '',
		template_version integer not null default 0,
		created integer not null,
		updated integer not null,
		synced integer not null default 0,
		populated integer not null default 1,
		access text not null default '',
		checked integer not null default 0
	)""")
	mochi.db.execute("create index if not exists crms_fingerprint on crms(fingerprint)")

	# 2. subscribers - subscribers to owned crms, and on a replica the owner's
	# roster (event_member_add), its owner's row first
	mochi.db.execute("""create table if not exists subscribers (
		crm text not null references crms(id),
		id text not null,
		name text not null default '',
		subscribed integer not null,
		sent integer not null default 0,
		primary key (crm, id)
	)""")
	mochi.db.execute("create index if not exists subscribers_id on subscribers(id)")

	# 3. classes - object classes (Task, Sub-item, Pull Request, etc.)
	mochi.db.execute("""create table if not exists classes (
		crm text not null references crms(id),
		id text not null,
		name text not null,
		rank integer not null default 0,
		title text not null default '',
		primary key (crm, id)
	)""")
	mochi.db.execute("create index if not exists classes_crm on classes(crm)")

	# 4. hierarchy - hierarchy rules (what can be parent of what)
	mochi.db.execute("""create table if not exists hierarchy (
		crm text not null references crms(id),
		class text not null,
		parent text not null default '',
		primary key (crm, class, parent),
		foreign key (crm, class) references classes(crm, id)
	)""")
	mochi.db.execute("create index if not exists hierarchy_crm on hierarchy(crm)")

	# 5. fields - field definitions per class
	mochi.db.execute("""create table if not exists fields (
		crm text not null references crms(id),
		class text not null,
		id text not null,
		name text not null,
		fieldtype text not null,
		flags text not null default '',
		multi integer not null default 0,
		rank integer not null default 0,
		min text not null default '',
		max text not null default '',
		pattern text not null default '',
		minlength integer not null default 0,
		maxlength integer not null default 0,
		prefix text not null default '',
		suffix text not null default '',
		format text not null default '',
		card integer not null default 1,
		position text not null default '',
		rows integer not null default 1,
		primary key (crm, class, id),
		foreign key (crm, class) references classes(crm, id)
	)""")
	mochi.db.execute("create index if not exists fields_crm on fields(crm)")
	mochi.db.execute("create index if not exists fields_class on fields(crm, class)")

	# 6. options - enumerated options for enumerated fields
	mochi.db.execute("""create table if not exists options (
		crm text not null references crms(id),
		class text not null,
		field text not null,
		id text not null,
		name text not null,
		colour text not null default '',
		icon text not null default '',
		rank integer not null default 0,
		primary key (crm, class, field, id),
		foreign key (crm, class, field) references fields(crm, class, id)
	)""")
	mochi.db.execute("create index if not exists options_field on options(crm, class, field)")

	# 7. views - board and list configurations
	mochi.db.execute("""create table if not exists views (
		crm text not null references crms(id),
		id text not null,
		name text not null,
		viewtype text not null default 'board',
		filter text not null default '',
		columns text not null default '',
		rows text not null default '',
		sort text not null default '',
		direction text not null default 'asc',
		rank integer not null default 0,
		border text not null default '',
		primary key (crm, id)
	)""")
	mochi.db.execute("create index if not exists views_crm on views(crm)")

	# 8. view_classes - which classes appear in a view (empty = all classes)
	mochi.db.execute("""create table if not exists view_classes (
		crm text not null,
		view text not null,
		class text not null,
		primary key (crm, view, class),
		foreign key (crm, view) references views(crm, id),
		foreign key (crm, class) references classes(crm, id)
	)""")

	# 9. view_fields - which fields appear in a view
	mochi.db.execute("""create table if not exists view_fields (
		crm text not null,
		view text not null,
		field text not null,
		rank integer not null default 0,
		primary key (crm, view, field),
		foreign key (crm, view) references views(crm, id)
	)""")

	# 10. objects - the actual tasks, epics, etc.
	mochi.db.execute("""create table if not exists objects (
		id text primary key,
		crm text not null references crms(id),
		class text not null,
		parent text not null default '',
		rank integer not null default 0,
		created integer not null,
		updated integer not null,
		version integer not null default 0,
		foreign key (crm, class) references classes(crm, id)
	)""")
	mochi.db.execute("create index if not exists objects_crm on objects(crm)")
	mochi.db.execute("create index if not exists objects_class on objects(crm, class)")
	mochi.db.execute("create index if not exists objects_parent on objects(parent)")
	mochi.db.execute("create index if not exists objects_rank on objects(crm, rank)")
	mochi.db.execute("create index if not exists objects_created on objects(created)")
	mochi.db.execute("create index if not exists objects_updated on objects(updated)")

	# 11. links - links between objects (blocks, relates to, duplicates, etc.)
	mochi.db.execute("""create table if not exists links (
		crm text not null references crms(id),
		source text not null references objects(id),
		target text not null references objects(id),
		linktype text not null,
		created integer not null,
		primary key (source, target, linktype)
	)""")
	mochi.db.execute("create index if not exists links_source on links(source)")
	mochi.db.execute("create index if not exists links_target on links(target)")
	mochi.db.execute("create index if not exists links_crm on links(crm)")

	# 12. values - field values on objects
	mochi.db.execute("""create table if not exists "values" (
		object text not null references objects(id),
		field text not null,
		value text not null default '',
		primary key (object, field)
	)""")
	mochi.db.execute("create index if not exists values_object on \"values\"(object)")
	mochi.db.execute("create index if not exists values_owner on \"values\"(value) where field='owner'")
	mochi.db.execute("create index if not exists values_field on \"values\"(field)")

	# 13. comments - comments on objects
	mochi.db.execute("""create table if not exists comments (
		id text primary key,
		object text not null references objects(id),
		parent text not null default '',
		author text not null,
		name text not null,
		content text not null,
		created integer not null,
		edited integer not null default 0
	)""")
	mochi.db.execute("create index if not exists comments_object on comments(object)")
	mochi.db.execute("create index if not exists comments_parent on comments(parent)")
	mochi.db.execute("create index if not exists comments_created on comments(created)")

	# 14. activity - activity history on objects
	mochi.db.execute("""create table if not exists activity (
		id text primary key,
		object text not null references objects(id),
		user text not null,
		action text not null,
		field text not null default '',
		oldvalue text not null default '',
		newvalue text not null default '',
		created integer not null
	)""")
	mochi.db.execute("create index if not exists activity_object on activity(object)")
	mochi.db.execute("create index if not exists activity_created on activity(created)")
	mochi.db.execute("create index if not exists activity_user on activity(user)")

	# 15. watchers - users subscribed to object updates
	mochi.db.execute("""create table if not exists watchers (
		object text not null references objects(id),
		user text not null,
		created integer not null,
		primary key (object, user)
	)""")
	mochi.db.execute("create index if not exists watchers_user on watchers(user)")

	# The chunks of an owner's sync batch a subscriber holds
	mochi.db.execute("create table if not exists chunks ( crm text not null, sync text not null, chunk integer not null, created integer not null default 0, primary key ( crm, sync, chunk ) )")

	# What a resync that runs past its own call may still prune
	mochi.db.execute("create table if not exists holdings ( crm text not null, pull text not null, list text not null, key text not null, primary key ( crm, pull, list, key ) )")

	# Attachments now live in this database, owned by the shared library.
	attachment_schema_create()
	attachment_schema_kind()

# handle is an open mochi.db.transaction(); statements issued through it are
# part of that transaction, and statements issued without it are not. A caller
# replacing several tables as one unit has to pass it all the way down.
#
# guard, when given, is a condition and its arguments the row is written under,
# checked in the same statement: a pull's part names the parent a row's foreign
# key needs, and a purge beside it could remove that parent between a separate
# check and the write.
#
# Each writer below binds one value to each placeholder, and refuses - writing
# nothing, answering False - a value that is a list, tuple or dict. Core spreads
# a list over the placeholders after it and refuses a tuple beside other values
# (db_parameters), and a peer's JSON array arrives as a tuple: bound by
# position, a tuple id once shifted every later value into the next column, the
# CRM's own among them, and the row landed in another CRM. A list a caller means
# to spread goes straight to mochi.db (rows_in, schema_keep, schema_prune).
def row_bindable(table, params):
	for value in params:
		if type(value) in ["list", "tuple", "dict"]:
			mochi.log.debug("Refusing a write to %s: a %s where one value belongs", table, type(value))
			return False
	return True

def row_merge(table, keys, row, handle=None, guard=None):
	cols = list(row)
	fields = [c for c in cols if c not in keys]
	conflict = "do update set " + ", ".join(["\"" + c + "\"=excluded.\"" + c + "\"" for c in fields]) if fields else "do nothing"
	params = [row[c] for c in cols]
	if guard:
		values = "select " + ", ".join(["?" for c in cols]) + " where " + guard[0]
		params = params + list(guard[1])
	else:
		values = "values (" + ", ".join(["?" for c in cols]) + ")"
	if not row_bindable(table, params):
		return False
	sql = "insert into \"" + table + "\" (" + ", ".join(["\"" + c + "\"" for c in cols]) + ") " + values + " on conflict (" + ", ".join(["\"" + k + "\"" for k in keys]) + ") " + conflict
	if handle:
		handle.execute(sql, *params)
	else:
		mochi.db.execute(sql, *params)
	return True

def row_set(table, where, args, updates, handle=None):
	fields = list(updates)
	params = [updates[c] for c in fields] + list(args)
	if not row_bindable(table, params):
		return False
	(handle or mochi.db).execute("update \"" + table + "\" set " + ", ".join(["\"" + c + "\"=?" for c in fields]) + " where (" + where + ")", *params)
	return True

def row_remove(table, where, args, handle=None):
	sql = "delete from \"" + table + "\" where (" + where + ")"
	if not row_bindable(table, list(args)):
		return False
	if handle:
		handle.execute(sql, *args)
	else:
		mochi.db.execute(sql, *args)
	return True

def row_rekey(table, where, args, newkeys):
	fields = list(newkeys)
	params = [newkeys[c] for c in fields] + list(args)
	if not row_bindable(table, params):
		return False
	mochi.db.execute("update \"" + table + "\" set " + ", ".join(["\"" + c + "\"=?" for c in fields]) + " where (" + where + ")", *params)
	return True

def object_merge(row, guard=None):
	row_merge("objects", ["id"], row, None, guard)

def comment_merge(row, guard=None):
	row_merge("comments", ["id"], row, None, guard)

# Whether value is an id in the shape mochi.uid() mints. Every object, comment
# and activity id a peer sends keys rows here and becomes a segment of the
# addresses the client fetches with the viewer's token, so nothing else is
# accepted from one.
def identifier(value):
	return type(value) == "string" and mochi.text.valid(value, "id")

# Whether an object or a comment, in any CRM of this database, holds id.
# Attachments and everything else keyed on a bare id would treat a new comment
# under such an id as that row.
def identifier_held(id):
	return mochi.db.exists("select 1 from objects where id=? union all select 1 from comments where id=?", id, id)

# True if this object/comment id names a row it may not: one of the other
# table, in any crm, or one of its own table under a DIFFERENT crm. Used to
# reject subscriber-path writes that a malicious crm owner could aim at the
# local user's OTHER crms, or at the other kind of row, by naming a colliding
# global id.
def foreign_object(object_id, crm_id):
	if not object_id:
		return False
	if mochi.db.exists("select 1 from comments where id=?", object_id):
		return True
	row = mochi.db.row("select crm from objects where id=?", object_id)
	return row != None and row["crm"] != crm_id

def foreign_comment(comment_id, crm_id):
	if not comment_id:
		return False
	if mochi.db.exists("select 1 from objects where id=?", comment_id):
		return True
	row = mochi.db.row("select o.crm from comments c join objects o on c.object=o.id where c.id=?", comment_id)
	return row != None and row["crm"] != crm_id

# A comment id alone says nothing about its CRM; requiring it to hang off an
# object already checked against the routed CRM settles it.
def comment_bound(comment_id, object_id):
	if not comment_id or not object_id:
		return False
	return mochi.db.exists("select 1 from comments where id=? and object=?", comment_id, object_id)

# comment_parent_check(comment_id, object_id, parent) -> where a comment a peer
# sends may hang: "ok" at the top ("") or under another comment of the same
# object whose own chain of parents does not pass through this one, "late"
# under a comment the replica does not hold yet, "refused" anywhere else - under
# itself, under another object's comment, or closing a loop. A loop would leave
# the comments in no thread, and deleting one would walk it.
def comment_parent_check(comment_id, object_id, parent):
	if parent == "":
		return "ok"
	if type(parent) != "string" or parent == comment_id:
		return "refused"
	row = mochi.db.row("select object, parent from comments where id=?", parent)
	if not row:
		return "late"
	if row["object"] != object_id:
		return "refused"
	total = mochi.db.row("select count(*) as n from comments where object=?", object_id)["n"]
	seen = {parent: True}
	current = row["parent"]
	for _ in range(total + 1):
		if not current:
			return "ok"
		if current == comment_id or current in seen:
			return "refused"
		seen[current] = True
		above = mochi.db.row("select parent from comments where id=? and object=?", current, object_id)
		if not above:
			return "ok"
		current = above["parent"]
	return "refused"

# Both endpoints must be objects in this CRM: links are keyed (source, target,
# linktype) with the CRM outside the key, so a row whose endpoints live
# elsewhere overwrites that CRM's own link.
def link_endpoints_bound(crm_id, source, target):
	if not source or not target:
		return False
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", source, crm_id):
		return False
	return mochi.db.exists("select 1 from objects where id=? and crm=?", target, crm_id)

# Whether an attachment owner, container of that kind, sits in this CRM: an
# object of it, or a comment on one of its objects. A comment's attachments are
# never judged as an object's, or the reverse.
def container_in_crm(container, kind, crm_id):
	if not container:
		return False
	if kind == "object":
		return mochi.db.exists("select 1 from objects where id=? and crm=?", container, crm_id)
	if kind == "comment":
		return mochi.db.exists("select 1 from comments c join objects o on o.id=c.object where c.id=? and o.crm=?", container, crm_id)
	return False

# attachment_delete keys on the attachment id alone, across every CRM in this
# database, so the id is not proof of anything on its own. Resolve the
# attachment's own owner and require it to sit in this CRM.
def attachment_in_crm(attachment_id, crm_id):
	attachment = attachment_row(attachment_id)
	if not attachment:
		return False
	return container_in_crm(attachment["object"], attachment.get("kind", "object"), crm_id)

# ============================================================================
# Templates
# ============================================================================

def safe_int(value, default=0):
	"""Convert value to int, returning default if not a valid integer."""
	s = str(value) if value else ""
	if not s:
		return default
	if s[0] == "-":
		return int(s) if decimal(s[1:]) else default
	return int(s) if decimal(s) else default

def check_length(value, max_len):
	"""Return True if value is a string exceeding max_len."""
	return value != None and len(str(value)) > max_len

# Read the user's BCP 47 language tag, or "en" if unset / anonymous
def user_language(a):
	if not a.user:
		return "en"
	pref = a.user.preference.get("language")
	if not pref:
		return "en"
	return str(pref).strip().lower()

# Strip the trailing hyphen-separated subtag. Mirrors core's strip_subtag.
def strip_subtag(lang):
	i = lang.rfind("-")
	if i < 0:
		return ""
	return lang[:i]

# Build the BCP 47 fallback chain for a language tag, as core resolves its own
# labels (language_fallbacks in core/server/labels.go): the tag, then the
# catalogue core redirects a variant to where stripping a subtag would not reach
# it (zh-hk and yue read zh-hant, es-ar reads es-419, nn reads nb), then parents
# one subtag at a time, always ending with "en". The resolver caller skips
# uninstalled tags. redirects is core's variant_redirects;
# claude/scripts/test_i18n_glossary.py holds the two together.
def language_fallbacks(lang):
	redirects = {"en-ph": "en-us", "zh-hk": "zh-hant", "yue": "zh-hant", "es-ar": "es-419", "nn": "nb"}
	lang = lang.strip().lower() if lang else ""
	if lang == "" or lang == "en":
		return ["en"]
	chain = [lang]
	parent = lang
	if lang in redirects:
		parent = redirects[lang]
		chain.append(parent)
	parent = strip_subtag(parent)
	for _ in range(8):
		if parent == "" or parent == "en":
			break
		chain.append(parent)
		parent = strip_subtag(parent)
	chain.append("en")
	return chain

# Parse the [labels] section of an INI string into a dict. Comments (# or ;)
# and lines outside [labels] are ignored. Last value wins within one file.
def parse_labels_conf(text):
	out = {}
	in_section = False
	for raw in text.split("\n"):
		line = raw.strip()
		if line == "" or line.startswith("#") or line.startswith(";"):
			continue
		if line.startswith("[") and line.endswith("]"):
			in_section = (line == "[labels]")
			continue
		if not in_section:
			continue
		eq = line.find("=")
		if eq < 0:
			continue
		key = line[:eq].strip()
		val = line[eq+1:].strip()
		if key:
			out[key] = val
	return out

# Load and merge labels for a template across the language fallback chain.
# Returns {key: value}; first language in the chain wins, so a French entry
# overrides English when both exist. Missing files are skipped silently.
def template_labels(template_id, lang):
	if not template_id or ".." in template_id or "/" in template_id:
		return {}
	available = {}
	files = mochi.app.asset.list("templates/" + template_id + "/labels") or []
	for f in files:
		if f.endswith(".conf"):
			tag = f[:-5].lower()
			available[tag] = f
	merged = {}
	for tag in language_fallbacks(lang):
		if tag not in available:
			continue
		content = mochi.app.asset.read("templates/" + template_id + "/labels/" + available[tag])
		if not content:
			continue
		parsed = parse_labels_conf(str(content))
		for k, v in parsed.items():
			if k not in merged:
				merged[k] = v
	return merged

# Replace {labels.X} placeholders in a string. Missing keys are left literal
# so the bug is visible rather than silently producing English fallback text.
def substitute_labels(text, labels):
	if not text or "{labels." not in text:
		return text
	for k, v in labels.items():
		ph = "{labels." + k + "}"
		if ph in text:
			text = text.replace(ph, v)
	if "{labels." in text:
		mochi.log.debug("Unresolved template label placeholder in: " + text)
	return text

# Get available crm templates from JSON files. Resolves template_name and
# template_description against `lang` so the template metadata is localised.
def get_templates(lang="en"):
	templates = {}
	files = mochi.app.asset.list("templates") or []
	for filename in files:
		if filename.endswith(".json"):
			content = mochi.app.asset.read("templates/" + filename)
			if content:
				data = json.decode(str(content))
				labels = template_labels(data["id"], lang)
				templates[data["id"]] = {
					"id": data["id"],
					"name": substitute_labels(data["name"], labels),
					"description": substitute_labels(data.get("description", ""), labels),
					"icon": data.get("icon", ""),
					"version": data.get("version", 1),
				}
	return templates

# Apply a template from its JSON file or from data. template_id selects the
# labels directory for {labels.X} substitution; without it, or without a labels
# directory, literal strings pass through unchanged.
def apply_template(crm_id, data=None, lang="en", template_id="crm", handle=None):
	# Load template JSON from file if no data provided
	if not data:
		if not template_id or ".." in template_id or "/" in template_id:
			return
		content = mochi.app.asset.read("templates/" + template_id + ".json")
		data = json.decode(str(content))

	# Load labels once and apply substitution to every user-facing name
	labels = template_labels(template_id, lang) if template_id else {}

	# Create classes
	for t in data.get("classes", []):
		row_merge("classes", ["crm", "id"], {"crm": crm_id, "id": t["id"], "name": substitute_labels(t["name"], labels), "rank": t.get("rank", 0), "title": t.get("title", "title")}, handle)

	# Set hierarchy for each class
	for cls_id, parents in data.get("hierarchy", {}).items():
		for parent in parents:
			row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": cls_id, "parent": parent}, handle)

	# Create fields for each class
	for cls_id, fields in data.get("fields", {}).items():
		for f in fields:
			row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": cls_id, "id": f["id"], "name": substitute_labels(f["name"], labels), "fieldtype": f.get("fieldtype", "text"), "flags": f.get("flags", ""), "multi": f.get("multi", 0), "rank": f.get("rank", 0), "min": f.get("min", ""), "max": f.get("max", ""), "pattern": f.get("pattern", ""), "minlength": f.get("minlength", 0), "maxlength": f.get("maxlength", 0), "prefix": f.get("prefix", ""), "suffix": f.get("suffix", ""), "format": f.get("format", ""), "card": f.get("card", 0), "position": f.get("position", ""), "rows": f.get("rows", 1)}, handle)

	# Create options for each class's enumerated fields
	for cls_id, class_options in data.get("options", {}).items():
		for field_id, field_options in class_options.items():
			for opt in field_options:
				row_merge("options", ["crm", "class", "field", "id"], {"crm": crm_id, "class": cls_id, "field": field_id, "id": opt["id"], "name": substitute_labels(opt["name"], labels), "colour": opt.get("colour", "#94a3b8"), "icon": opt.get("icon", ""), "rank": opt.get("rank", 0)}, handle)

	# Create views
	for i, v in enumerate(data.get("views", [])):
		row_merge("views", ["crm", "id"], {"crm": crm_id, "id": v["id"], "name": substitute_labels(v["name"], labels), "viewtype": v.get("viewtype", "board"), "filter": v.get("filter", ""), "columns": v.get("columns", ""), "rows": v.get("rows", ""), "sort": v.get("sort", ""), "direction": v.get("direction", "asc"), "rank": i, "border": v.get("border", "")}, handle)
		# Add view classes if specified
		for vclass in v.get("classes", []):
			row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": v["id"], "class": vclass}, handle)
		# Add fields
		fields = v.get("fields", "").split(",")
		for j, field in enumerate(fields):
			if field.strip():
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": v["id"], "field": field.strip(), "rank": j}, handle)

# Snapshot the design (classes, fields, options, hierarchy, views) as template
# JSON holding the literal names the CRM currently holds, not {labels.X}
# placeholders. Shared by design/export and data/export.
def design_export(crm_id):

	# Read classes
	classes = []
	class_rows = mochi.db.rows("select id, name, rank, title from classes where crm=? order by rank", crm_id) or []
	for c in class_rows:
		classes.append({
			"id": c["id"],
			"name": c["name"],
			"rank": c["rank"],
			"title": c["title"],
		})

	# Read hierarchy
	hierarchy = {}
	for h in mochi.db.rows("select class, parent from hierarchy where crm=?", crm_id) or []:
		hierarchy.setdefault(h["class"], []).append(h["parent"])

	# Read fields: one query, grouped by class in rank order
	fields = {}
	for f in mochi.db.rows(
		"select class, id, name, fieldtype, flags, multi, rank, min, max, pattern, minlength, maxlength, prefix, suffix, format, card, position, rows from fields where crm=? order by class, rank",
		crm_id
	) or []:
		field = {
			"id": f["id"],
			"name": f["name"],
			"fieldtype": f["fieldtype"],
			"flags": f["flags"],
			"card": f["card"],
			"rank": f["rank"],
			"rows": f["rows"],
		}
		for key in ["multi", "position", "min", "max", "pattern", "minlength", "maxlength", "prefix", "suffix", "format"]:
			if f[key]:
				field[key] = f[key]
		fields.setdefault(f["class"], []).append(field)

	# Read options: one query, kept only for enumerated fields
	enumerated = {}
	for class_id, class_fields in fields.items():
		for f in class_fields:
			if f["fieldtype"] == "enumerated":
				enumerated[(class_id, f["id"])] = True
	options = {}
	for opt in mochi.db.rows("select class, field, id, name, colour, icon, rank from options where crm=? order by class, field, rank", crm_id) or []:
		if (opt["class"], opt["field"]) not in enumerated:
			continue
		o = {
			"id": opt["id"],
			"name": opt["name"],
			"colour": opt["colour"],
			"rank": opt["rank"],
		}
		if opt["icon"]:
			o["icon"] = opt["icon"]
		options.setdefault(opt["class"], {}).setdefault(opt["field"], []).append(o)

	# Read views, with their fields and classes fetched once each
	vf_map = {}
	for vf in mochi.db.rows("select view, field from view_fields where crm=? order by rank", crm_id) or []:
		vf_map.setdefault(vf["view"], []).append(vf["field"])
	vc_map = {}
	for vc in mochi.db.rows("select view, class from view_classes where crm=?", crm_id) or []:
		vc_map.setdefault(vc["view"], []).append(vc["class"])
	views = []
	view_rows = mochi.db.rows("select id, name, viewtype, filter, columns, rows, sort, direction, rank, border from views where crm=? order by rank", crm_id) or []
	for v in view_rows:
		view = {
			"id": v["id"],
			"name": v["name"],
			"viewtype": v["viewtype"],
		}
		for key in ["filter", "columns", "rows", "sort", "border"]:
			if v[key]:
				view[key] = v[key]
		if v["direction"] and v["direction"] != "asc":
			view["direction"] = v["direction"]
		if v["id"] in vf_map:
			view["fields"] = ",".join(vf_map[v["id"]])
		if v["id"] in vc_map:
			view["classes"] = vc_map[v["id"]]
		views.append(view)

	return {
		"classes": classes,
		"fields": fields,
		"options": options,
		"hierarchy": hierarchy,
		"views": views,
	}

# Export the current crm design as template JSON
def action_design_export(a):

	# Remote crms are exportable too: the subscriber's replica holds the full
	# design, and require_crm applies the standard remote semantics (owner
	# enforces access at sync time; per-user databases isolate subscribers).
	crm_id, crm = require_crm(a, "design")
	if not crm_id:
		return

	return {"data": design_export(crm_id)}

# Replace a crm's design with data; deletes run in foreign-key order.
# template_id lets {labels.X} placeholders resolve; literal names pass through
# because substitute_labels short-circuits without one.
def design_replace(crm_id, data, lang, template_id, handle=None):
	# One transaction: a failure between the deletes and apply_template must not
	# leave a CRM with no design. An uncommitted handle is rolled back when the
	# Starlark thread tears down, so error paths need no explicit rollback. With
	# a caller's handle the replacement is part of the caller's transaction,
	# which the caller commits.
	owned = handle == None
	if owned:
		handle = mochi.db.transaction()
	row_remove("view_fields", "crm=?", [crm_id], handle)
	row_remove("view_classes", "crm=?", [crm_id], handle)
	row_remove("views", "crm=?", [crm_id], handle)
	row_remove("options", "crm=?", [crm_id], handle)
	row_remove("fields", "crm=?", [crm_id], handle)
	row_remove("hierarchy", "crm=?", [crm_id], handle)
	# Objects reference classes and SQLite checks that foreign key per deleted row,
	# not at commit, so a class still holding records cannot be dropped and
	# re-created. Remove only the classes the new design drops; apply_template
	# upserts the rest.
	keep = [c["id"] for c in data.get("classes", [])] if type(data) == "dict" else []
	for row in handle.rows("select id from classes where crm=?", crm_id) or []:
		if row["id"] not in keep:
			row_remove("classes", "crm=? and id=?", [crm_id, row["id"]], handle)
	apply_template(crm_id, data, lang, template_id, handle)
	if owned:
		handle.commit()

# The values a field's type, a view's type and a view's sort direction may
# take: the single-item actions refuse anything else, and an imported design is
# held to the same sets (design_invalid).
FIELD_TYPES = ["text", "number", "date", "enumerated", "user", "object", "checkbox", "checklist"]
VIEW_TYPES = ["board", "list"]
VIEW_DIRECTIONS = ["asc", "desc"]

# design_id: is value an id the design editor could have produced? Ids are
# URL segments and members of the comma-separated view lists, so only what
# structural_id emits is admissible; anything else breaks a route or a list.
def design_id(value):
	return type(value) == "string" and len(value) > 0 and len(value) <= 100 and structural_id(value) == value

# design_integer: an absent or integer attribute. A string in an integer
# column lands by affinity or aborts the replace mid-transaction.
def design_integer(value):
	return value == None or type(value) == "int"

# design_text: an absent or string attribute. A list or dict in a text column
# is refused by the database part-way through the replacement.
def design_text(value):
	return value == None or type(value) == "string"

# design_member: an absent attribute, or one of the values allowed.
def design_member(value, allowed):
	return value == None or (type(value) == "string" and value in allowed)

# A design is arbitrary user-supplied JSON, and apply_template indexes into it
# by shape - classes and views as lists, hierarchy, fields and options as dicts
# keyed by class - so the wrong shape raises part-way through the replacement.
# Each attribute is held to its type, and an enumerated one to the values the
# single-item actions allow. Returns an error key, or None when the design can
# be applied.
def design_invalid(data):
	if type(data) != "dict":
		return "errors.invalid_design"
	if type(data.get("classes", [])) != "list" or type(data.get("views", [])) != "list":
		return "errors.invalid_design"
	for key in ["hierarchy", "fields", "options"]:
		if type(data.get(key, {})) != "dict":
			return "errors.invalid_design"
	for c in data.get("classes", []):
		if type(c) != "dict" or not design_id(c.get("id")) or type(c.get("name")) != "string":
			return "errors.invalid_design"
		if not design_integer(c.get("rank")) or not design_text(c.get("title")):
			return "errors.invalid_design"
	for parents in data.get("hierarchy", {}).values():
		if type(parents) not in ["list", "tuple"]:
			return "errors.invalid_design"
		for parent in parents:
			if type(parent) != "string":
				return "errors.invalid_design"
	for fields in data.get("fields", {}).values():
		if type(fields) not in ["list", "tuple"]:
			return "errors.invalid_design"
		for f in fields:
			if type(f) != "dict" or not design_id(f.get("id")) or type(f.get("name")) != "string":
				return "errors.invalid_design"
			if not design_member(f.get("fieldtype"), FIELD_TYPES):
				return "errors.invalid_design"
			for key in ["rank", "multi", "card", "rows", "minlength", "maxlength"]:
				if not design_integer(f.get(key)):
					return "errors.invalid_design"
			for key in ["flags", "position", "min", "max", "pattern", "prefix", "suffix", "format"]:
				if not design_text(f.get(key)):
					return "errors.invalid_design"
	for class_options in data.get("options", {}).values():
		if type(class_options) != "dict":
			return "errors.invalid_design"
		for field_options in class_options.values():
			if type(field_options) not in ["list", "tuple"]:
				return "errors.invalid_design"
			for opt in field_options:
				if type(opt) != "dict" or not design_id(opt.get("id")) or type(opt.get("name")) != "string":
					return "errors.invalid_design"
				if not design_integer(opt.get("rank")) or not design_text(opt.get("colour")) or not design_text(opt.get("icon")):
					return "errors.invalid_design"
	for v in data.get("views", []):
		if type(v) != "dict" or not design_id(v.get("id")) or type(v.get("name")) != "string":
			return "errors.invalid_design"
		if not design_integer(v.get("rank")):
			return "errors.invalid_design"
		if not design_member(v.get("viewtype"), VIEW_TYPES) or not design_member(v.get("direction"), VIEW_DIRECTIONS):
			return "errors.invalid_design"
		for key in ["filter", "columns", "rows", "sort", "border"]:
			if not design_text(v.get(key)):
				return "errors.invalid_design"
		if type(v.get("classes", [])) not in ["list", "tuple"]:
			return "errors.invalid_design"
		if type(v.get("fields", "")) != "string":
			return "errors.invalid_design"
	return None

# objects carries a foreign key to classes, so a class that still holds records
# cannot be deleted. Name the classes the incoming design drops while they are
# still in use, so the caller can refuse before writing anything.
def design_classes_missing(crm_id, data):
	incoming = [c["id"] for c in data.get("classes", [])]
	missing = []
	for row in mochi.db.rows("select distinct class from objects where crm=?", crm_id) or []:
		if row["class"] not in incoming:
			missing.append(row["class"])
	return sorted(missing, key=lambda name: mochi.text.sortkey(name))

# Name the classes and fields a design references without defining, so the
# caller can refuse before the foreign keys fail mid-replacement. Hierarchy
# parents and view field lists are not checked: no foreign key covers them and
# an export may carry stale entries there.
def design_references_missing(data):
	classes = [c["id"] for c in data.get("classes", [])]
	fields = {}
	for cls, class_fields in data.get("fields", {}).items():
		fields[cls] = [f["id"] for f in class_fields]
	missing = []
	for cls in data.get("hierarchy", {}):
		if cls not in classes:
			missing.append("hierarchy[" + cls + "]")
	for cls in data.get("fields", {}):
		if cls not in classes:
			missing.append("fields[" + cls + "]")
	for cls, class_options in data.get("options", {}).items():
		if cls not in classes:
			missing.append("options[" + cls + "]")
			continue
		for field in class_options:
			if field not in fields.get(cls, []):
				missing.append("options[" + cls + "][" + field + "]")
	for v in data.get("views", []):
		for cls in v.get("classes", []):
			if type(cls) != "string" or cls not in classes:
				missing.append("views[" + v["id"] + "][" + str(cls) + "]")
	return sorted(missing, key=lambda name: mochi.text.sortkey(name))

def action_design_import(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		a.error.label(400, "errors.cannot_import_design_to_remote_crm")
		return

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	data_str = a.input("data")
	template_id = a.input("template") or ""
	template_version = safe_int(a.input("version"))
	lang = user_language(a)

	if data_str and len(data_str) > 1000000:
		a.error.label(400, "errors.design_data_too_large")
		return

	if len(template_id) > 100:
		a.error.label(400, "errors.template_id_too_long")
		return

	# Load design data from JSON string or from built-in template file
	data = None
	if data_str:
		data = json.decode(data_str, None)
	elif template_id:
		templates = get_templates(lang)
		if template_id not in templates:
			a.error.label(400, "errors.invalid_template")
			return
		content = mochi.app.asset.read("templates/" + template_id + ".json")
		data = json.decode(str(content), None)
		template_version = templates[template_id]["version"]
	else:
		a.error.label(400, "errors.design_data_or_template_is_required")
		return

	# Everything that can refuse this design refuses it before the first write.
	problem = design_invalid(data)
	if problem:
		a.error.label(400, problem)
		return

	dangling = design_references_missing(data)
	if dangling:
		a.error.label(400, "errors.design_reference_unknown", references=", ".join(dangling))
		return

	missing = design_classes_missing(crm_id, data)
	if missing:
		a.error.label(400, "errors.design_class_in_use", classes=", ".join(missing))
		return

	design_replace(crm_id, data, lang, template_id)

	# Update template tracking
	row_set("crms", "id=?", [crm_id], {"template": template_id, "template_version": template_version})

	# Every class, field, option, rule and view was rewritten, and what the new
	# design dropped is gone: subscribers pull the CRM afresh, which prunes what
	# their copies still hold of the old one (event_design_replace).
	broadcast_event(crm_id, "design/replace", {"crm": crm_id})

	return {"data": {"success": True}}

# Collect an object's (or, with kind "comment", a comment's) attachments for a
# data export: an archive entry each, named in the manifest with the size it
# holds, which the import holds the entry to. attachment_entry pulls remote
# bytes over P2P for subscribed crms. An attachment whose bytes cannot be read
# (deleted file, unreachable owner) is left out rather than failing the whole
# export, and listed in skipped, which the manifest carries.
def export_attachments(object_id, crm_id, frm, entries, skipped, kind="object"):
	result = []
	for att in attachment_list(object_id, crm_id, kind) or []:
		name = "files/" + att["id"]
		entry = attachment_entry(att["id"], name, frm)
		if entry == None:
			skipped.append({"id": att["id"], "name": att["name"], "object": object_id, "kind": kind})
			continue
		entries.append(entry)
		result.append({
			"name": att["name"],
			"content_type": att.get("content_type", ""),
			"caption": att.get("caption", ""),
			"description": att.get("description", ""),
			"entry": name,
			"size": att.get("size", 0),
		})
	return result

# Warm the local attachment cache before a data export: a remote crm pulls bytes
# over P2P on first use and a large one cannot fetch them all in one action.
# Runs up to 20 seconds and reports how many remain, and how many of those it
# tried it could not fetch (failed), which the export will leave out; callers
# loop until none remain.
def action_data_export_warm(a):

	crm_id, crm = require_crm(a, "view")
	if not crm_id:
		return

	identifiers = []
	for row in mochi.db.rows("select id from objects where crm=? order by rank, id", crm_id) or []:
		for att in attachment_list(row["id"], crm_id) or []:
			identifiers.append(att["id"])
		for c in mochi.db.rows("select id from comments where object=?", row["id"]) or []:
			for att in attachment_list(c["id"], crm_id, "comment") or []:
				identifiers.append(att["id"])

	start = mochi.time.now()
	failed = 0
	for i, identifier in enumerate(identifiers):
		# Under the Android client's 30-second read timeout.
		if mochi.time.now() - start > 20:
			return {"data": {"attachments": len(identifiers), "remaining": len(identifiers) - i, "failed": failed}}
		if not attachment_fetch(identifier, a.user.identity.id):
			failed += 1

	return {"data": {"attachments": len(identifiers), "remaining": 0, "failed": failed}}

# Export the crm as format 2 JSON with a design snapshot, so the file reproduces
# the crm on any instance: metadata, objects and values, comments, attachments,
# activity and links, by rank. Watchers are per-user and excluded; objects whose
# parent is missing locally are pruned with their links so the file passes its
# own import.
def action_data_export(a):

	# Remote crms export from the subscriber's replica - the same tables the
	# board reads - so the file matches what the user sees.
	crm_id, crm = require_crm(a, "view")
	if not crm_id:
		return

	# Values are filtered against the design snapshot: orphan rows for a removed
	# field would fail the file's own import. Attachment bytes travel as archive
	# entries, not inline base64, so no export holds every attachment in memory at
	# once. An attachment whose bytes could not be read is named in skipped.
	entries = []
	skipped = []

	design = design_export(crm_id)
	declared = {}
	for class_id, class_fields in design["fields"].items():
		for f in class_fields:
			declared[class_id + "/" + f["id"]] = True

	rows = mochi.db.rows("select id, class, parent, created, updated from objects where crm=? order by rank, created desc, id desc", crm_id) or []

	# Prune orphans: an object whose parent has no local row is unreachable in
	# the app and would fail the file's own import validation. Repeat so a
	# chain of orphans prunes fully; each pass removes at least one or stops.
	present = {}
	for row in rows:
		present[row["id"]] = True
	for _ in rows:
		changed = False
		for row in rows:
			if row["id"] in present and row["parent"] and row["parent"] not in present:
				present.pop(row["id"])
				changed = True
		if not changed:
			break
	# An object whose chain of parents comes back on itself is as unreachable,
	# and the import refuses the loop.
	for id in parent_loops({row["id"]: row["parent"] for row in rows if row["id"] in present}):
		present.pop(id)

	# Values, comments and activity for every exported object at once, rather
	# than three queries per object.
	ids = [row["id"] for row in rows if row["id"] in present]
	values_map = {}
	comments_map = {}
	activity_map = {}
	if ids:
		for v in rows_in("select object, field, value from \"values\" where object in (", ids, ")"):
			values_map.setdefault(v["object"], []).append(v)
		for c in rows_in("select object, id, parent, author, name, content, created, edited from comments where object in (", ids, ") order by created, id"):
			comments_map.setdefault(c["object"], []).append(c)
		for act in rows_in("select object, user, action, field, oldvalue, newvalue, created from activity where object in (", ids, ") order by created, id"):
			activity_map.setdefault(act["object"], []).append(act)

	objects = []
	for row in rows:
		if row["id"] not in present:
			continue
		object = {
			"id": row["id"],
			"class": row["class"],
			"created": row["created"],
			"updated": row["updated"],
		}
		if row["parent"]:
			object["parent"] = row["parent"]
		values = {}
		for v in values_map.get(row["id"], []):
			if v["value"] != "" and (row["class"] + "/" + v["field"]) in declared:
				values[v["field"]] = v["value"]
		if values:
			object["values"] = values
		comments = []
		# A reply names another comment of the object, as the import requires; a
		# parent the object does not hold, or a chain of parents that loops, is
		# left off and the comment exported at the top.
		threads = {c["id"]: c["parent"] for c in comments_map.get(row["id"], [])}
		looped = parent_loops(threads)
		for c in comments_map.get(row["id"], []):
			comment = {
				"id": c["id"],
				"author": c["author"],
				"name": c["name"],
				"content": c["content"],
				"created": c["created"],
			}
			if c["parent"] and c["parent"] in threads and c["id"] not in looped:
				comment["parent"] = c["parent"]
			if c["edited"]:
				comment["edited"] = c["edited"]
			attachments = export_attachments(c["id"], crm_id, a.user.identity.id, entries, skipped, "comment")
			if attachments:
				comment["attachments"] = attachments
			comments.append(comment)
		if comments:
			object["comments"] = comments
		attachments = export_attachments(row["id"], crm_id, a.user.identity.id, entries, skipped)
		if attachments:
			object["attachments"] = attachments
		activity = []
		for act in activity_map.get(row["id"], []):
			activity.append({
				"user": act["user"],
				"action": act["action"],
				"field": act["field"],
				"oldvalue": act["oldvalue"],
				"newvalue": act["newvalue"],
				"created": act["created"],
			})
		if activity:
			object["activity"] = activity
		objects.append(object)

	links = []
	for l in mochi.db.rows("select source, target, linktype, created from links where crm=? order by created, source, target", crm_id) or []:
		if l["source"] not in present or l["target"] not in present:
			continue
		links.append({
			"source": l["source"],
			"target": l["target"],
			"linktype": l["linktype"],
			"created": l["created"],
		})

	result = {
		"format": 3,
		"crm": {"name": crm["name"], "description": crm["description"]},
		"design": design,
		"objects": objects,
	}
	if links:
		result["links"] = links
	# What the file lacks: each attachment whose bytes could not be read, by its
	# id, name and the object or comment it belongs to. The response is the
	# archive itself, so the warm-up's failed count is what a client can show.
	if skipped:
		result["skipped"] = skipped

	# Built in cache and deleted once served: an export is a download, not stored
	# state, and cache resolves for the requesting user where file storage reads as
	# the entity owner, so a subscriber exporting another's crm writes and reads
	# the same place.
	archive = "exports/" + mochi.uid() + ".zip"
	entries.append({"name": "manifest.json", "data": json.encode(result)})
	mochi.archive.write(archive, entries, cache=True)
	a.write.cache(archive, content_type="application/zip")
	mochi.cache.delete(archive)

# Validate and decode a container's attachment list in place for an import:
# each entry must be a dict with a name and either an archive entry or base64
# data. An entry must be one the archive holds (listing, {name: size}), at the
# size the manifest records for it when it records one, and no larger than the
# platform stores as one object; its size is kept on the entry, so staging
# holds the extraction to it. Inline data is replaced with the decoded bytes so
# the write phase never re-decodes. Returns None, or (status, key, arguments)
# for the first entry the import refuses.
def import_attachments_decode(container, archive, listing):
	attachments = container.get("attachments") or []
	if type(attachments) != "list":
		return (400, "errors.invalid_data", {})
	for att in attachments:
		if type(att) != "dict" or type(att.get("name")) != "string" or not att["name"]:
			return (400, "errors.invalid_data", {})
		# Format 3 names an entry in the archive; the bytes go straight from
		# there to their resting place and are never a value here. Format 2
		# carried them base64-encoded inline, and still imports.
		entry = att.get("entry")
		if entry != None:
			if type(entry) != "string":
				return (400, "errors.invalid_data", {})
			if not archive or entry not in listing:
				return (400, "errors.import_attachment_damaged", {"name": attachment_name(att["name"])})
			size = att.get("size")
			if size != None and (type(size) != "int" or size != listing[entry]):
				return (400, "errors.import_attachment_damaged", {"name": attachment_name(att["name"])})
			if listing[entry] > mochi.file.maximum():
				return (400, "errors.data_too_large", {})
			att["size"] = listing[entry]
			continue
		if type(att.get("data")) != "string":
			return (400, "errors.invalid_data", {})
		data = mochi.decode.base64(att["data"])
		if data == None:
			return (400, "errors.invalid_data", {})
		att["data"] = data
	return None

# Remove staged archives an earlier import abandoned: Starlark has no finally,
# so a later import collects rather than each exit deleting. Anything over an
# hour old has no writer - no handler outlives the Starlark time limit.
def import_discard(archive):
	"""Remove a staged import upload, if one was staged. The JSON path passes ""
	and every refusal below can call this without knowing which path it took."""
	if archive:
		mochi.file.delete(archive)

def import_staging_sweep():
	if not mochi.file.exists("imports"):
		return
	for entry in mochi.file.list("imports") or []:
		name = entry.get("name", "") if type(entry) == "dict" else entry
		if not name:
			continue
		age = mochi.file.age("imports/" + name)
		if age != None and age > 3600:
			mochi.file.delete("imports/" + name)

# Put down the file of one imported attachment, recording no row, and answer
# what attachment_insert records for it, or None. Format 3 streams from the
# archive, held to the size import_attachments_decode settled; format 2 has the
# bytes in hand.
def import_attachment_stage(archive, att):
	if type(att.get("entry")) == "string":
		return attachment_unpack(archive, att["entry"], att["name"], att.get("content_type") or "", att["size"])
	return attachment_stage(att["name"], att["data"], att.get("content_type") or "")

# parent_loops(parents) -> {id: True} for every id of parents ({id: parent})
# whose chain of parents, followed within parents, comes back to an id it has
# already passed instead of reaching the top; a chain that leaves parents ends
# there. An object or comment in such a chain is in no tree, and deleting it
# would walk the loop.
def parent_loops(parents):
	looped = {}
	settled = {}
	for start in parents:
		path = []
		seen = {}
		current = start
		loop = False
		for _ in range(len(parents) + 1):
			if not current or current not in parents or current in settled:
				break
			if current in looped or current in seen:
				loop = True
				break
			seen[current] = True
			path.append(current)
			current = parents[current]
		for id in path:
			if loop:
				looped[id] = True
			else:
				settled[id] = True
	return looped

# import_check(crm_id, objects, links, classes, hierarchy, archive, listing)
# -> None, or (status, key, arguments) for the first thing the import
# refuses. Every value the write phase binds or indexes is checked for its type
# here, so nothing the file holds can abort the write part-way. An object's
# parent is another object of the file or one the CRM holds, a comment's parent
# another comment of the same object, and neither chain of parents may loop.
def import_check(crm_id, objects, links, classes, hierarchy, archive, listing):
	invalid = (400, "errors.invalid_data", {})
	imported = {}
	parents = {}
	for o in objects:
		if type(o) != "dict" or type(o.get("id")) != "string" or not o["id"] or type(o.get("class")) != "string" or not o["class"]:
			return invalid
		parent = o.get("parent") or ""
		if o["id"] in imported or type(parent) != "string":
			return invalid
		imported[o["id"]] = o["class"]
		parents[o["id"]] = parent
	if parent_loops(parents):
		return (400, "errors.cannot_set_parent_would_create_a_cycle", {})
	for o in objects:
		if o["class"] not in classes:
			return (400, "errors.unknown_class", {"name": o["class"]})
		parent = parents[o["id"]]
		parent_class = ""
		if parent:
			if parent in imported:
				parent_class = imported[parent]
			else:
				row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
				if not row:
					return (404, "errors.parent_object_not_found", {})
				parent_class = row["class"]
		if (o["class"] + "/" + parent_class) not in hierarchy:
			return (400, "errors.hierarchy_disallowed", {})
		values = o.get("values") or {}
		if type(values) != "dict":
			return invalid
		for field, value in values.items():
			if type(field) != "string" or type(value) not in ["string", "int", "float", "bool"]:
				return invalid
		comments = o.get("comments") or []
		if type(comments) != "list":
			return invalid
		threads = {}
		for c in comments:
			if type(c) != "dict" or type(c.get("content")) != "string" or not c["content"]:
				return invalid
			for key in ["id", "parent", "name"]:
				if c.get(key) != None and type(c[key]) != "string":
					return invalid
			if c.get("id"):
				if c["id"] in threads:
					return invalid
				threads[c["id"]] = c.get("parent") or ""
			problem = import_attachments_decode(c, archive, listing)
			if problem:
				return problem
		for c in comments:
			if c.get("parent") and c["parent"] not in threads:
				return (400, "errors.parent_comment_not_found", {})
		if parent_loops(threads):
			return (400, "errors.cannot_set_parent_would_create_a_cycle", {})
		problem = import_attachments_decode(o, archive, listing)
		if problem:
			return problem
		activity = o.get("activity") or []
		if type(activity) != "list":
			return invalid
		for act in activity:
			if type(act) != "dict" or type(act.get("action")) != "string" or not act["action"]:
				return invalid
			if act.get("user") != None and type(act["user"]) != "string":
				return invalid
			for key in ["field", "oldvalue", "newvalue"]:
				if act.get(key) != None and type(act[key]) not in ["string", "int", "float", "bool"]:
					return invalid
	for l in links:
		if type(l) != "dict" or type(l.get("source")) != "string" or not l["source"] or type(l.get("target")) != "string" or not l["target"]:
			return invalid
		if type(l.get("linktype")) != "string" or l["linktype"] not in LINK_TYPES:
			return (400, "errors.invalid_link", {})
		for end in [l["source"], l["target"]]:
			if end not in imported and not mochi.db.exists("select 1 from objects where id=? and crm=?", end, crm_id):
				return (400, "errors.invalid_link", {})
	return None

# import_refuse(a, archive, staged, problem) answers a refused import with its
# translated error, after removing the upload and every attachment file staged
# for it so far (staged, file names).
def import_refuse(a, archive, staged, problem):
	for file in staged:
		mochi.file.delete(file)
	import_discard(archive)
	a.error.label(problem[0], problem[1], **problem[2])

# A comment's author is kept when it is a well-formed identity id, since it
# decides who may edit or delete the comment; anything else is attributed to
# the importer. The name is display-only.
def import_author(value, importer):
	return value if type(value) == "string" and mochi.text.valid(value, "entity") else importer

def import_design(crm_id, design):
	"""Membership maps an import is validated against, keyed "class",
	"class/field" and "class/parent": from the file's design when the import
	applies one, else from the current tables."""
	classes = {}
	fields = {}
	hierarchy = {}
	if design != None:
		for c in design.get("classes", []):
			classes[c["id"]] = True
		for cls, members in design.get("fields", {}).items():
			for f in members:
				fields[cls + "/" + f["id"]] = True
		for cls, parents in design.get("hierarchy", {}).items():
			for parent in parents:
				if type(parent) == "string":
					hierarchy[cls + "/" + parent] = True
		return classes, fields, hierarchy
	for c in mochi.db.rows("select id from classes where crm=?", crm_id) or []:
		classes[c["id"]] = True
	for f in mochi.db.rows("select class, id from fields where crm=?", crm_id) or []:
		fields[f["class"] + "/" + f["id"]] = True
	for h in mochi.db.rows("select class, parent from hierarchy where crm=?", crm_id) or []:
		hierarchy[h["class"] + "/" + h["parent"]] = True
	return classes, fields, hierarchy

# Import a data/export snapshot. Objects and comments get fresh ids with in-file
# references remapped, so importing twice creates two copies; objects append
# below existing ones in file order. With design set, the file's own design
# replaces the CRM's; otherwise the design must already hold every class the
# file references. Everything is validated before anything is written, the
# attachment files are put down next, and the design and every row are then
# written in one transaction.
def action_data_import(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		a.error.label(400, "errors.cannot_import_data_to_remote_crm")
		return

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	# An upload streams to disk rather than becoming a value: a format 3
	# archive carries the attachment bytes, and reading those into memory to
	# find the manifest would undo what the container is for. A format 2 file
	# is JSON all through and is read as before.
	archive = ""
	# Each archive entry's uncompressed size, by name, as the archive declares it.
	listing = {}
	data_string = a.input("data")
	if not data_string and a.files("file"):
		import_staging_sweep()
		staged = "imports/" + mochi.uid()
		a.upload("file", staged)
		entries = mochi.archive.list(staged)
		if entries != None:
			archive = staged
			for entry in entries:
				if type(entry.get("name")) == "string" and type(entry.get("size")) == "int":
					listing[entry["name"]] = entry["size"]
			# Check the declared uncompressed size from archive.list before reading: a
			# bound applied after archive.read has already materialised the string.
			if listing.get("manifest.json", 0) > IMPORT_MAXIMUM:
				import_discard(archive)
				a.error.label(400, "errors.data_too_large")
				return
			data_string = str(mochi.archive.read(staged, "manifest.json") or "")
		else:
			# A format 2 file is read whole, so it is held to the same bound,
			# checked against the file on disk before any of it is read.
			content = mochi.file.read(staged, maximum=IMPORT_MAXIMUM)
			mochi.file.delete(staged)
			if content == None:
				a.error.label(400, "errors.data_too_large")
				return
			data_string = str(content)
	if not data_string:
		import_discard(archive)
		a.error.label(400, "errors.data_is_required")
		return
	if len(data_string) > IMPORT_MAXIMUM:
		import_discard(archive)
		a.error.label(400, "errors.data_too_large")
		return
	data = json.decode(data_string, None)
	if type(data) != "dict":
		import_discard(archive)
		a.error.label(400, "errors.invalid_data")
		return

	# A container carries the design its objects were validated against; applying
	# it here restores a backup in one upload (the client cannot parse
	# archive-entry attachments to sequence it itself). Nothing is written until
	# the whole file has passed, so a refused import leaves the design as it was.
	design = None
	if a.input("design") and type(data.get("design")) == "dict":
		problem = design_invalid(data["design"])
		if problem:
			import_discard(archive)
			a.error.label(400, problem)
			return
		dangling = design_references_missing(data["design"])
		if dangling:
			import_discard(archive)
			a.error.label(400, "errors.design_reference_unknown", references=", ".join(dangling))
			return
		missing = design_classes_missing(crm_id, data["design"])
		if missing:
			import_discard(archive)
			a.error.label(400, "errors.design_class_in_use", classes=", ".join(missing))
			return
		design = data["design"]

	objects = data.get("objects") or []
	links = data.get("links") or []
	if type(objects) != "list" or type(links) != "list":
		import_discard(archive)
		a.error.label(400, "errors.invalid_data")
		return
	if not objects and not links:
		import_discard(archive)
		a.error.label(400, "errors.nothing_to_import")
		return

	# The design the objects are validated against: the file's own when it is
	# being applied, else the current one.
	classes, fields, hierarchy = import_design(crm_id, design)

	# Validate everything before writing anything
	problem = import_check(crm_id, objects, links, classes, hierarchy, archive, listing)
	if problem:
		import_refuse(a, archive, [], problem)
		return

	# Every attachment's file goes down first, each held to its size; one that
	# does not arrive whole refuses the import, and the files staged before it
	# go with the upload. A storage limit reached here aborts the action, and
	# the files staged so far, which no row names, are the orphan sweep's
	# (attachment_sweep). Each attachment keeps what it staged, for its row.
	staged = []
	for o in objects:
		for container in (o.get("comments") or []) + [o]:
			for att in container.get("attachments") or []:
				stage = import_attachment_stage(archive, att)
				if not stage:
					import_refuse(a, archive, staged, (400, "errors.data_too_large", {}) if att.get("data") != None else (400, "errors.import_attachment_damaged", {"name": attachment_name(att["name"])}))
					return
				staged.append(attachment_filename(stage["id"], stage["name"]))
				att["staged"] = stage

	now = mochi.time.now()
	user = a.user.identity.id

	# Fresh ids for every imported object, assigned up front so forward
	# references (a parent later in the file) remap correctly
	remap = {}
	for o in objects:
		remap[o["id"]] = mochi.uid()

	# The design replacement and every row of the import go through one
	# transaction, committed once at the end, so the import lands whole or not
	# at all: an abort part-way rolls everything back, the design included. It
	# holds the database's write lock throughout, so a move or a create during
	# the import cannot mint a key the import also writes; the objects append
	# below the crm-wide maximum key, in file order (see rank_after_all). Every
	# read and write until the commit goes through the handle.
	lang = user_language(a)
	handle = mochi.db.transaction()
	if design != None:
		design_replace(crm_id, design, lang, "", handle)
	row = handle.row("select max(rank) as r from objects where crm=?", crm_id)
	previous = row["r"] if (row and row["r"]) else None
	for o in objects:
		parent = o.get("parent") or ""
		previous = rank_between(previous, None)
		created = safe_int(o.get("created")) or now
		updated = safe_int(o.get("updated")) or now
		row_merge("objects", ["id"], {"id": remap[o["id"]], "crm": crm_id, "class": o["class"], "parent": remap.get(parent, parent), "rank": previous, "created": created, "updated": updated}, handle)

	comment_count = 0
	attachment_count = 0
	for o in objects:
		object_id = remap[o["id"]]
		# Values for fields the design doesn't declare are skipped, not
		# rejected: older exports can carry orphan values from fields that
		# were later removed from the design, and the app never renders them.
		for field, value in (o.get("values") or {}).items():
			if value != "" and (o["class"] + "/" + field) in fields:
				row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": str(value)}, handle)
		file_comments = o.get("comments") or []
		comment_ids = []
		comment_remap = {}
		for c in file_comments:
			comment_id = mochi.uid()
			comment_ids.append(comment_id)
			if c.get("id"):
				comment_remap[c["id"]] = comment_id
		for i, c in enumerate(file_comments):
			comment_parent = comment_remap.get(c.get("parent") or "", "")
			row_merge("comments", ["id"], {"id": comment_ids[i], "object": object_id, "parent": comment_parent, "author": import_author(c.get("author"), user), "name": c.get("name") or a.user.identity.name, "content": c["content"], "created": safe_int(c.get("created")) or now, "edited": safe_int(c.get("edited"))}, handle)
			comment_count += 1
			for att in c.get("attachments") or []:
				attachment_insert(handle, comment_ids[i], att["staged"], att.get("caption") or "", att.get("description") or "", "comment")
				attachment_count += 1
		for att in o.get("attachments") or []:
			attachment_insert(handle, object_id, att["staged"], att.get("caption") or "", att.get("description") or "")
			attachment_count += 1
		file_activity = o.get("activity") or []
		if file_activity:
			for act in file_activity:
				handle.execute(
					"insert into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
					mochi.uid(), object_id, act.get("user") or user, act["action"], str(act.get("field") or ""), str(act.get("oldvalue") or ""), str(act.get("newvalue") or ""), safe_int(act.get("created")) or now
				)
		else:
			handle.execute(
				"insert into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, 'created', '', '', '', ?)",
				mochi.uid(), object_id, user, now
			)

	# Both ends in this CRM, read through the transaction: an end the file
	# names is one of the objects just written, and one it does not was
	# checked above but may have been deleted since.
	for l in links:
		source = remap.get(l["source"], l["source"])
		target = remap.get(l["target"], l["target"])
		if not handle.exists("select 1 from objects where id=? and crm=?", source, crm_id) or not handle.exists("select 1 from objects where id=? and crm=?", target, crm_id):
			continue
		row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": source, "target": target, "linktype": l["linktype"], "created": safe_int(l.get("created")) or now}, handle)

	row_set("crms", "id=?", [crm_id], {"updated": now}, handle)
	handle.commit()

	import_discard(archive)

	# Subscribers are told once the import has committed. A design the import
	# applied may have dropped classes, fields, options or views, which a sync
	# batch only adds to: they pull the CRM afresh instead, which prunes what the
	# old design left and brings the imported rows with it (event_design_replace).
	# Otherwise the whole CRM is sent to each member who may still view it (the
	# owner's own identity left out: a batch addressed to it would find no
	# replica and unsubscribe the owner), built once for them all;
	# event_sync_batch applies it idempotently, which replaces per-record
	# broadcasts for a bulk change.
	if design != None:
		broadcast_event(crm_id, "design/replace", {"crm": crm_id})
	else:
		members, stale = recipients(crm_id)
		send_crm_data(crm_id, [m["id"] for m in members or []])

	return {"data": {"objects": len(objects), "comments": comment_count, "attachments": attachment_count, "links": len(links)}}

# ============================================================================
# CRM Actions
# ============================================================================

# List user's crms
def action_crm_list(a):

	rows = mochi.db.rows("""select p.id, p.name, p.description, p.owner, p.server, p.created, p.updated,
		(select s.name from subscribers s where s.crm=p.id order by s.subscribed asc, s.rowid asc limit 1) as ownername
		from crms p order by p.updated desc""")
	crms = []
	for row in rows or []:
		crms.append({
			"id": row["id"],
			"fingerprint": mochi.entity.fingerprint(row["id"]),
			"name": row["name"],
			"description": row["description"],
			"owner": {"local": row["owner"] == 1, "name": row["ownername"] or ""},
			"server": row["server"],
			"created": row["created"],
			"updated": row["updated"],
		})
	return {"data": {"crms": crms}}

# Create a new crm
def action_crm_create(a):

	name = a.input("name")
	if not name or not mochi.text.valid(name, "name"):
		a.error.label(400, "errors.invalid_name")
		return

	description = a.input("description") or ""
	# privacy decides whether the directory lists the CRM and nothing else;
	# readable whether anyone may view it.
	privacy = a.input("privacy") or "private"
	if privacy not in ("public", "private"):
		a.error.label(400, "errors.invalid_data")
		return
	readable = a.input("readable")
	if readable == None:
		# A client that predates readable sends none, and by public it meant
		# anyone may view. Drop this once clients that send readable have
		# shipped, leaving a missing readable members-only.
		readable = "true" if privacy == "public" else "false"
	readable = readable or "false"
	if readable not in ("true", "false"):
		a.error.label(400, "errors.invalid_data")
		return

	if len(description) > 10000:
		a.error.label(400, "errors.description_too_long")
		return

	# Load CRM template version
	lang = user_language(a)
	templates = get_templates(lang)
	tmpl_version = templates.get("crm", {}).get("version", 1)

	# Create Mochi entity
	entity = mochi.entity.create("crm", name, privacy, description)
	if not entity:
		a.error.label(500, "errors.failed_to_create_crm_entity")
		return

	now = mochi.time.now()
	creator = a.user.identity.id

	# Insert CRM record
	fp = mochi.entity.fingerprint(entity) or ""
	row_merge("crms", ["id"], {"id": entity, "name": name, "description": description, "owner": 1, "server": "", "fingerprint": fp, "template": "crm", "template_version": tmpl_version, "created": now, "updated": now})

	# Add creator as subscriber
	row_merge("subscribers", ["crm", "id"], {"crm": entity, "id": creator, "name": a.user.identity.name, "subscribed": now})

	# Apply CRM template
	apply_template(entity, None, lang, "crm")

	# Set up access control: anyone may view a readable CRM and nothing more;
	# the owner grants anything else on the Access tab.
	resource = "crm/" + entity
	if readable == "true":
		access_ceiling("*", resource, "view", creator)
	else:
		mochi.access.deny("*", resource, "view", creator)
		mochi.access.deny("+", resource, "view", creator)
	mochi.access.allow(creator, resource, "*", creator)

	return {"data": {"id": entity, "fingerprint": mochi.entity.fingerprint(entity)}}

# Get crm details
def action_crm_get(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	row = mochi.db.row("select id, name, description, owner, server, template, template_version, created, updated, populated, access, checked from crms where id=?", crm_id)
	if not row:
		a.error.label(404, "errors.crm_not_found")
		return

	# Re-establish with the owner if this subscription has gone idle.
	maybe_resubscribe(a, crm_id)

	# Get classes
	classes = mochi.db.rows("select id, name, rank, title from classes where crm=? order by rank", crm_id) or []

	# Get all fields in one query, group by class
	fields = {}
	all_fields = mochi.db.rows("select " + ", ".join(FIELD_COLUMNS) + " from fields where crm=? order by class, rank", crm_id) or []
	for f in all_fields:
		fields.setdefault(f["class"], []).append(f)

	# Get all options in one query, group by class and field
	options = {}
	all_options = mochi.db.rows("select class, field, id, name, colour, icon, rank from options where crm=? order by class, field, rank", crm_id) or []
	for o in all_options:
		options.setdefault(o["class"], {}).setdefault(o["field"], []).append(o)

	# Get views
	views = mochi.db.rows("select id, name, viewtype, filter, columns, rows, sort, direction, rank, border from views where crm=? order by rank, name", crm_id) or []

	# Batch-fetch view classes and fields
	all_view_classes = mochi.db.rows("select view, class from view_classes where crm=?", crm_id) or []
	vc_map = {}
	for vc in all_view_classes:
		vc_map.setdefault(vc["view"], []).append(vc["class"])
	all_view_fields = mochi.db.rows("select view, field from view_fields where crm=? order by rank", crm_id) or []
	vf_map = {}
	for vf in all_view_fields:
		vf_map.setdefault(vf["view"], []).append(vf["field"])
	for v in views:
		v["classes"] = vc_map.get(v["id"], [])
		v["fields"] = ",".join(vf_map.get(v["id"], []))

	# Get all hierarchy in one query, group by class
	hierarchy = {}
	all_hierarchy = mochi.db.rows("select class, parent from hierarchy where crm=?", crm_id) or []
	for h in all_hierarchy:
		hierarchy.setdefault(h["class"], []).append(h["parent"])

	# Determine access level
	if row["owner"] == 1:
		resource = "crm/" + crm_id
		if mochi.access.check(a.user.identity.id, resource, "*"):
			access = "owner"
		elif check_crm_access(a.user.identity.id, crm_id, "design"):
			access = "design"
		elif check_crm_access(a.user.identity.id, crm_id, "write"):
			access = "write"
		elif check_crm_access(a.user.identity.id, crm_id, "comment"):
			access = "comment"
		elif check_crm_access(a.user.identity.id, crm_id, "view"):
			access = "view"
		else:
			a.error.label(403, "errors.access_denied")
			return
	elif row["access"]:
		# The level the owner last confirmed answers at once, and the owner is
		# asked again after answering (schedule_access), at most once per
		# access_interval: stamped first, and only by the view that moves the
		# stamp, so views arriving together - or a page reloading every few
		# seconds while it fills - schedule one. The level only decides which
		# controls show: every write goes to the owner, which checks it, and a
		# revoke purges the replica (access/revoke). It also keeps the replica
		# readable while the owner is unreachable. A level that moves reaches a
		# page already listening as crm/update; one opened after the frame shows
		# it on its next load.
		access = row["access"]
		now = mochi.time.now()
		if now - row["checked"] >= access_interval and mochi.db.execute("update crms set checked=? where id=? and checked=?", now, crm_id, row["checked"]) > 0:
			mochi.schedule.after("schedule_access", {"crm": crm_id}, 0)
	else:
		access, response = access_ask(crm_id, row)
		if access == None:
			# The owner's own status code is not passed on: a hostile one could
			# answer 401 and sign the reader out.
			remote_error(a, response if response and response.get("transport") else None)
			return
		if not access:
			a.error.label(403, "errors.access_denied")
			return

	return {"data": {
		"crm": {
			"id": row["id"],
			"fingerprint": mochi.entity.fingerprint(row["id"]),
			"name": row["name"],
			"description": row["description"],
			"owner": {"local": row["owner"] == 1, "name": crm_owner_name(crm_id)},
			"server": row["server"],
			"template": {"id": row["template"], "version": row["template_version"]},
			"created": row["created"],
			"updated": row["updated"],
			"populated": row["populated"],
			"access": access,
		},
		"classes": classes,
		"fields": fields,
		"options": options,
		"views": views,
		"hierarchy": hierarchy,
	}}

# Update crm
def action_crm_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	row = mochi.db.row("select id, owner from crms where id=?", crm_id)
	if not row:
		a.error.label(404, "errors.crm_not_found")
		return

	if row["owner"] != 1:
		a.error.label(403, "errors.cannot_update_remote_crm")
		return

	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error.label(403, "errors.access_denied")
		return

	name = a.input("name")
	description = a.input("description")

	now = mochi.time.now()

	if name:
		if not mochi.text.valid(name, "name"):
			a.error.label(400, "errors.invalid_name")
			return
		row_set("crms", "id=?", [crm_id], {"name": name, "updated": now})
		mochi.entity.update(crm_id, name=name)

	if a.input("description") != None:
		if len(description) > 10000:
			a.error.label(400, "errors.description_too_long")
			return
		row_set("crms", "id=?", [crm_id], {"description": description, "updated": now})
		mochi.entity.update(crm_id, data=description)
	update = {"crm": crm_id}
	if name:
		update["name"] = name
	if a.input("description") != None:
		update["description"] = description
	broadcast_event(crm_id, "crm/update", update)

	return {"data": {"success": True}}

# Force a fresh schema pull from the owner on demand; the event handlers
# self-heal through request_resync on the next bad event.
def action_crm_resync(a):
	if not a.user:
		a.error.label(401, "errors.not_logged_in")
		return
	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return
	row = mochi.db.row("select id, owner from crms where id=?", crm_id)
	if not row:
		a.error.label(404, "errors.crm_not_found")
		return
	if row["owner"] != 0:
		return {"data": {"synced": False}}
	# Answered after the first part, as a subscribe is: each further part may
	# take 30 seconds to arrive, past what a client waits. A continuation takes
	# the rest, and synced says whether the first was the last. It starts at
	# once, whatever pull is under way or ran in the last minute.
	synced = request_resync(crm_id, False, 0, True)
	return {"data": {"synced": synced}}

# Remove every local row of a CRM with physical deletes, not tombstones: this is
# per-host housekeeping for unsubscribe, owner delete and the owner's deleted
# notice, and a tombstone would make a later re-subscribe skip the row. Children
# before parents so the foreign keys hold.
def purge_crm(crm_id):
	# A pull of the CRM under way stops first: it looks for its own row in
	# holdings before and after each part it applies (schema_current).
	mochi.db.execute("delete from holdings where crm=?", crm_id)
	# Attachments next, and here rather than at a call site: they are addressed
	# through the comment and object rows deleted below, so clearing them
	# afterwards finds nothing.
	delete_crm_comment_attachments(crm_id)
	for obj in (mochi.db.rows("select id from objects where crm=?", crm_id) or []):
		attachment_clear(obj["id"])
	# The rows go in one transaction. A part a pull applies beside the purge
	# then lands wholly before it, and goes with the rest, or wholly after,
	# where every row it writes needs a parent that is gone (schema_merge's
	# guards) and is not written. Interleaved, a child landing between its own
	# table's delete and its parent's made the parent's fail on its foreign key.
	# The attachments a part stored after the clearing above go here too.
	handle = mochi.db.transaction()
	handle.execute("delete from holdings where crm=?", crm_id)
	handle.execute("delete from attachments where entity!='' and ((kind='object' and object in (select id from objects where crm=?)) or (kind='comment' and object in (select c.id from comments c join objects o on o.id=c.object where o.crm=?)))", crm_id, crm_id)
	handle.execute("delete from watchers where object in (select id from objects where crm=?)", crm_id)
	handle.execute("delete from activity where object in (select id from objects where crm=?)", crm_id)
	handle.execute("delete from comments where object in (select id from objects where crm=?)", crm_id)
	handle.execute("delete from \"values\" where object in (select id from objects where crm=?)", crm_id)
	handle.execute("delete from links where crm=?", crm_id)
	handle.execute("delete from objects where crm=?", crm_id)
	handle.execute("delete from view_fields where crm=?", crm_id)
	handle.execute("delete from view_classes where crm=?", crm_id)
	handle.execute("delete from views where crm=?", crm_id)
	handle.execute("delete from options where crm=?", crm_id)
	handle.execute("delete from fields where crm=?", crm_id)
	handle.execute("delete from hierarchy where crm=?", crm_id)
	handle.execute("delete from classes where crm=?", crm_id)
	handle.execute("delete from subscribers where crm=?", crm_id)
	handle.execute("delete from chunks where crm=?", crm_id)
	handle.execute("delete from crms where id=?", crm_id)
	handle.commit()

def action_crm_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	row = mochi.db.row("select id, owner from crms where id=?", crm_id)
	if not row:
		a.error.label(404, "errors.crm_not_found")
		return

	if row["owner"] != 1:
		a.error.label(403, "errors.cannot_delete_remote_crm")
		return

	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error.label(403, "errors.access_denied")
		return

	# Attachment cleanup now lives in purge_crm, so every teardown path gets it.
	# Notify subscribers that crm is being deleted (before purging the
	# subscriber list). Send from the CRM entity so receivers can verify the
	# sender, matching broadcast_event and the verify_subscription check.
	# Core's replay record of each goes with their row, as on every other path
	# a subscriber row is deleted by (subscriber_remove).
	subscribers = mochi.db.rows("select id from subscribers where crm=?", crm_id)
	for sub in subscribers:
		mochi.message.send(p2p_headers(crm_id, sub["id"], "deleted"), {"crm": crm_id})
		mochi.broadcast.subscriber.remove(crm_id, sub["id"])

	purge_crm(crm_id)
	# Delete entity
	mochi.entity.delete(crm_id)

	return {"data": {"success": True}}

# List crm members (subscribers + unique owners + current user)
def action_people_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	# Collect unique people with names
	people = {}

	# Always include current user first so they can assign to themselves
	people[a.user.identity.id] = {"id": a.user.identity.id, "name": a.user.identity.name}

	# Add subscribers (already have names stored)
	subscribers = mochi.db.rows("select id, name from subscribers where crm=?", crm_id) or []
	for sub in subscribers:
		if sub["id"] not in people:
			people[sub["id"]] = {"id": sub["id"], "name": sub["name"] or person_name(sub["id"])}

	# Everyone a user field of an object names, whatever the field is called
	values = mochi.db.rows(
		"select distinct v.value as value from \"values\" v join objects o on o.id=v.object join fields f on f.crm=o.crm and f.class=o.class and f.id=v.field where o.crm=? and f.fieldtype='user' and v.value!=''",
		crm_id
	) or []
	for row in values:
		person = row["value"]
		if person not in people and mochi.text.valid(person, "entity"):
			people[person] = {"id": person, "name": person_name(person)}

	return {"data": {"people": list(people.values())}}

# person_name(id) -> string: what a person is called, their entity's name or
# else its fingerprint; "" for an id that names no entity.
def person_name(id):
	if mochi.text.valid(id, "entity"):
		return mochi.entity.name(id) or mochi.entity.fingerprint(id)
	if mochi.text.valid(id, "fingerprint"):
		return mochi.entity.name(id) or id
	return ""

# ============================================================================
# Access Control
# ============================================================================

# Access levels for crms (from most to least permissive)
ACCESS_LEVELS = ["design", "write", "comment", "view"]

# Check if a user has cumulative access to a crm at the given level
def check_crm_access(user_id, crm_id, level):
	resource = "crm/" + crm_id
	# One call rather than one per level: core settles each operation the same
	# way it would alone, but builds the subject list - which costs a
	# group-membership walk - once instead of once per level. broadcast_event
	# runs this per subscriber, so the walk was being repeated five times for
	# every recipient of every event.
	levels = ["view", "comment", "write", "design"]
	if level not in levels:
		return mochi.access.check.any(user_id, resource, ["*"])
	return mochi.access.check.any(user_id, resource, ["*"] + levels[levels.index(level):])

# access_ceiling(subject, resource, level, granter): make level the most the
# subject may do on resource. Its rules are replaced by an allow for every
# operation the level includes and a deny for each level above it ("none"
# denies all four), so its own rows decide every operation before a group's,
# "+"'s or "*"'s broader grant is reached. A group's "none" is a single "*"
# deny instead: core takes a group's "*" deny as a veto over every group's
# grant on the resource, where its denies of the four levels would lose to
# another group's allow, and a member of a group the owner gave no access
# would keep what another of their groups gives.
def access_ceiling(subject, resource, level, granter):
	included = ACCESS_LEVELS[ACCESS_LEVELS.index(level):] if level in ACCESS_LEVELS else []
	if subject.startswith("@") and level == "none":
		rules = {"*": False}
	else:
		rules = {op: op in included for op in ACCESS_LEVELS}
	# In one write where core offers it, so a failure part way cannot leave the
	# subject with some of its rules or none.
	if hasattr(mochi.access, "replace"):
		mochi.access.replace(subject, resource, rules, granter)
		return
	for op in ACCESS_LEVELS + ["*"]:
		mochi.access.revoke(subject, resource, op)
	for op, grant in rules.items():
		if grant:
			mochi.access.allow(subject, resource, op, granter)
		else:
			mochi.access.deny(subject, resource, op, granter)

# access_veto(resource): give each group whose rules on resource allow nothing
# the single "*" deny a group's "No access" is (access_ceiling).
def access_veto(resource):
	groups = {}
	for rule in mochi.access.list.resource(resource) or []:
		subject = rule.get("subject") or ""
		if subject.startswith("@"):
			groups.setdefault(subject, []).append(rule)
	for subject, rules in groups.items():
		if [rule for rule in rules if rule.get("grant")]:
			continue
		if len(rules) == 1 and rules[0].get("operation") == "*":
			continue
		access_ceiling(subject, resource, "none", rules[0].get("granter") or "")

# access_widen(resource): after "*" is given a level, drop the deny of view "+"
# holds when that is all it holds, as a CRM made without readable has it. "+"
# decides before "*", so the row would keep every signed-in non-member out
# while anonymous visitors took the level; without it "+" falls through to
# "*", as the Access tab then shows. A level the owner gave "+" stays.
def access_widen(resource):
	rules = [r for r in (mochi.access.list.resource(resource) or []) if r.get("subject") == "+"]
	if len(rules) == 1 and rules[0].get("operation") == "view" and not rules[0].get("grant"):
		mochi.access.revoke("+", resource, "view")

# access_fold(rules) -> list: one rule per subject, in the order core lists
# them, whose operation is the level the subject's rows amount to: the "*" row
# of a holder of the wildcard, else the highest level allowed, else "none"
# with grant 0.
def access_fold(rules):
	order = []
	held = {}
	for rule in rules or []:
		subject = rule.get("subject", "")
		if subject not in held:
			order.append(subject)
			held[subject] = []
		held[subject].append(rule)
	folded = []
	for subject in order:
		chosen = None
		for rule in held[subject]:
			if rule.get("operation") == "*" and rule.get("grant"):
				chosen = rule
		if not chosen:
			# Lowest first, so the highest level allowed is the one left.
			for level in reversed(ACCESS_LEVELS):
				for rule in held[subject]:
					if rule.get("operation") == level and rule.get("grant"):
						chosen = rule
		if not chosen:
			chosen = dict(held[subject][0])
			chosen["operation"] = "none"
			chosen["grant"] = 0
		folded.append(chosen)
	return folded

# access_rewrite(resource): re-set every subject allowed anything on resource
# as a ceiling at the highest level it is allowed. A subject holding a "*"
# row, the owner's own among them, keeps its rows.
def access_rewrite(resource):
	rules = mochi.access.list.resource(resource) or []
	wildcard = {}
	for rule in rules:
		if rule.get("operation") == "*":
			wildcard[rule.get("subject")] = True
	for rule in access_fold(rules):
		subject = rule.get("subject")
		if subject in wildcard or rule.get("operation") not in ACCESS_LEVELS or not rule.get("grant"):
			continue
		access_ceiling(subject, resource, rule["operation"], rule.get("granter") or "")

# The swimlane half of a move arrives as {"field", "value"}: a JSON string over
# HTTP (core stringifies object values in a JSON body, and form callers encode
# it themselves) and a dict over P2P. Anything else reads as no row move.
def row_input(value):
	if type(value) == "string":
		value = json.decode(value, None) if value else None
	if type(value) != "dict":
		return "", ""
	field = value.get("field")
	row_value = value.get("value")
	return (field if type(field) == "string" else "", row_value if type(row_value) == "string" else "")

# Display name of the crm's owner: the anchor subscriber row.
def crm_owner_name(crm_id):
	row = mochi.db.row("select name from subscribers where crm=? order by subscribed, rowid limit 1", crm_id)
	return (row["name"] if row else "") or ""

# Forward a subscriber action to the crm owner via P2P. `handled` names error
# keys the CALLER recovers from itself — those return the raw error dict
# instead of writing the response, so the caller can fall back (e.g. the
# phantom-comment cleanup in action_comment_delete).
def forward_to_owner(a, crm_id, action, params, handled=None):
	# Look up the server for this remote crm and resolve peer
	server_row = mochi.db.row("select server from crms where id=?", crm_id)
	server = server_row["server"] if server_row else ""
	peer = mochi.remote.peer(server) if server else None
	# Authorship is set from the authenticated P2P sender on the owner side, so
	# only the display name travels, never an identity the owner would trust.
	result = mochi.remote.request(crm_id, "crm", "request", {
		"action": action,
		"params": params,
		"name": a.user.identity.name,
	}, peer)
	if not result:
		a.error.label(502, "errors.could_not_reach_crm_owner")
		return None
	if result.get("error"):
		if handled and result["error"] in handled:
			return {"error": result["error"], "code": remote_status(result, 500), "args": result.get("args")}
		# The error field is a label key; resolve it in the requester's language,
		# with any ICU args the owner returned alongside it.
		a.error.label(remote_status(result, 500), result["error"], **(result.get("args") or {}))
		return None
	return {"data": result}

# List access rules for a crm
def action_access_list(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	# Only owner can manage access
	if crm["owner"] != 1:
		a.error.label(403, "errors.access_denied")
		return
	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error.label(403, "errors.access_denied")
		return

	# Get owner info
	owner = {"id": a.user.identity.id, "name": a.user.identity.name}

	resource = "crm/" + crm_id
	# A level is stored as one row per operation (access_ceiling); the list
	# shows each subject once, at its level.
	rules = access_fold(mochi.access.list.resource(resource))

	# Resolve names for rules and mark owner. Cached per distinct subject:
	# an access list commonly names the same person or group across several
	# rules, and both lookups go to core.
	filtered_rules = []
	names = {}
	for rule in rules:
		subject = rule.get("subject", "")
		# Mark owner rules
		if subject == owner.get("id"):
			rule["owner"] = True
		# Resolve names for non-special subjects
		if subject and subject not in ("*", "+") and not subject.startswith("#"):
			if subject not in names:
				if subject.startswith("@"):
					# Look up group name
					group_id = subject[1:]
					group = mochi.group.get(group_id)
					names[subject] = group.get("name", group_id) if group else subject
				else:
					names[subject] = person_name(subject)
			rule["name"] = names[subject]
		filtered_rules.append(rule)

	return {"data": {"rules": filtered_rules, "owner": owner}}

# Set access level for a subject
def action_access_set(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	# Only owner can manage access
	if crm["owner"] != 1:
		a.error.label(403, "errors.access_denied")
		return
	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error.label(403, "errors.access_denied")
		return

	subject = a.input("subject")
	level = a.input("level")

	if not subject:
		a.error.label(400, "errors.user_or_group_required")
		return
	if len(subject) > 255:
		a.error.label(400, "errors.subject_too_long")
		return

	if not level:
		a.error.label(400, "errors.level_is_required")
		return

	if level not in ["view", "comment", "write", "design", "none"]:
		a.error.label(400, "errors.invalid_level")
		return

	resource = "crm/" + crm_id

	# The gate above is the "*" grant, and the revoke below takes "*" with it,
	# so letting the caller name themselves is a one-way door: every route back
	# into this action is gated on the grant they just dropped.
	if subject == a.user.identity.id:
		a.error.label(400, "errors.cannot_change_your_own_access")
		return

	# The level is a ceiling: what a group, "+" or "*" grants beyond it does
	# not reach the subject.
	access_ceiling(subject, resource, level, a.user.identity.id)
	if subject == "*" and level != "none":
		access_widen(resource)

	# A level of "none", or replacing a broader rule, narrows access - drop
	# any subscriber the change cut off and purge their replica.
	subscribers_revalidate(crm_id)

	return {"data": {"success": True}}

# Revoke access for a subject
def action_access_revoke(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	# Only owner can manage access
	if crm["owner"] != 1:
		a.error.label(403, "errors.access_denied")
		return
	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error.label(403, "errors.access_denied")
		return

	subject = a.input("subject")

	if not subject:
		a.error.label(400, "errors.user_or_group_required")
		return
	if len(subject) > 255:
		a.error.label(400, "errors.subject_too_long")
		return

	resource = "crm/" + crm_id

	# Revoke all rules for this subject
	for op in ACCESS_LEVELS + ["*"]:
		mochi.access.revoke(subject, resource, op)

	# Removing a subject's rules narrows its access, or widens it to what a
	# group, "+" or "*" rule gives it once its own ceiling is gone - drop any
	# subscriber the change cut off, stop their fan-out, and tell their server
	# to purge its replica.
	subscribers_revalidate(crm_id)

	return {"data": {"success": True}}

# ============================================================================
# Object Templates
# ============================================================================

# ============================================================================
# Helper Functions
# ============================================================================

def resolve_crm(a):
	"""Resolve crm ID from param, handling fingerprints."""
	crm_id = a.input("crm")
	if not crm_id:
		return None
	if mochi.text.valid(crm_id, "fingerprint"):
		row = mochi.db.row("select id from crms where fingerprint=?", crm_id)
		if row:
			return row["id"]
		return None
	return crm_id

def get_crm(crm_id):
	"""Get crm row or None."""
	row = mochi.db.row("select * from crms where id=?", crm_id)
	if not row:
		row = mochi.db.row("select * from crms where fingerprint=?", crm_id)
	return row

def require_crm(a, level="view"):
	"""Resolve CRM, check existence and access. Returns (crm_id, crm) or (None, None) on error."""
	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return None, None
	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return None, None
	if crm["owner"] == 1 and not check_crm_access(a.user.identity.id, crm_id, level):
		a.error.label(403, "errors.access_denied")
		return None, None
	return crm_id, crm

def log_activity(object_id, user, action, field="", oldvalue="", newvalue="", handle=None, events=None):
	"""Log an activity entry for an object and replicate it to subscribers
	when this host owns the CRM. Subscribers insert the same row by UID
	so the activity table stays a converged append-only log. Within a
	transaction (handle) the entry is written through it and its broadcast
	added to events, for events_commit."""
	database = handle or mochi.db
	activity_id = mochi.uid()
	now = mochi.time.now()
	database.execute(
		"insert into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
		activity_id, object_id, user, action, field, str(oldvalue), str(newvalue), now
	)
	owned = database.row(
		"select o.crm from objects o join crms c on c.id=o.crm where o.id=? and c.owner=1",
		object_id
	)
	if owned:
		data = {
			"crm": owned["crm"], "id": activity_id, "object": object_id,
			"user": user, "action": action, "field": field,
			"oldvalue": str(oldvalue), "newvalue": str(newvalue), "created": now,
		}
		if events != None:
			events.append({"event": "activity/log", "data": data})
		else:
			broadcast_event(owned["crm"], "activity/log", data)

# events_commit(crm_id, events, handle): send subscribers the events a change
# gathered ({event, data}, in order) with its transaction (handle), then commit
# it. They are handed over while the transaction holds the write lock every
# change of an object takes its version under (version_take), so the CRM's
# broadcasts, which core numbers and each subscriber applies in turn, follow
# the order of its versions. Sent after the commit, a later change's could go
# first, and a copy holding its version would drop the earlier change, fields
# only that one wrote included. Core sends them as the transaction commits, in
# commit order, and none for a change rolled back; an older core sends each at
# once (broadcast_event). A subscriber failing the view check is dropped
# (subscribers_revalidate) once the change has committed.
def events_commit(crm_id, events, handle):
	stale = False
	for event in events:
		if broadcast_event(crm_id, event["event"], event["data"], None, handle):
			stale = True
	handle.commit()
	if stale:
		subscribers_revalidate(crm_id)

def get_owner_identity(crm_id, handle=None):
	"""Get the crm owner's identity from the first subscriber. The owner row
	is inserted at creation, before any real subscriber, so rowid breaks a
	same-second subscribed tie; on a replica the owner's row is held at
	subscribed 0 (member_owner). Within a transaction (handle) the read goes
	through it."""
	row = (handle or mochi.db).row("select id from subscribers where crm=? order by subscribed, rowid limit 1", crm_id)
	return row["id"] if row else ""

def get_object_display(crm, obj, object_id):
	"""Build display title: '<crm name> - <object title>'."""
	title_field_row = mochi.db.row("select title from classes where crm=? and id=?", crm["id"], obj["class"]) if obj else None
	title_field = title_field_row["title"] if title_field_row else ""
	title_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, title_field) if title_field else None
	obj_title = title_row["value"] if title_row else ""
	return crm["name"] + " - " + obj_title if obj_title else crm["name"]

def notify_watchers(object_id, crm_id, local_identity, user_id, body):
	"""Notify local user if they watch this object and didn't make the change."""
	if local_identity == user_id:
		return
	watching = mochi.db.exists("select 1 from watchers where object=? and user=?", object_id, local_identity)
	if not watching:
		return
	crm = get_crm(crm_id)
	if not crm:
		return
	obj = mochi.db.row("select class from objects where id=?", object_id)
	if not obj:
		return
	title = get_object_display(crm, obj, object_id)
	fp = mochi.entity.fingerprint(crm_id)
	url = "/crm/" + fp + "/" + object_id if fp else "/crm"
	mochi.log.debug("notify_watchers: notifying " + str(local_identity) + " about " + str(object_id))
	notify("update/modified", crm_id, title, body, url, event_id="update/modified:" + object_id)

def notify_mentions(object_id, crm_id, content, author_id, author_name):
	"""Notify each @mentioned subscriber on their OWN host.

	notify() writes into the calling principal's notification store - there is
	no recipient argument - so raising it here would tell the comment's author
	that they had been mentioned and tell the mentioned subscriber nothing.
	Same shape as forums and feeds: one message per recipient. The members are
	those every other fan-out reaches (recipients: view access rechecked), and
	the owner, whose own message comes back to this server."""
	content_lower = content.lower()
	members, stale = recipients(crm_id)
	if members == None:
		return
	owner = mochi.db.row("select id, name from subscribers where crm=? and id=?", crm_id, get_owner_identity(crm_id))
	if owner:
		members = [{"id": owner["id"], "name": owner["name"]}] + members
	subscribers = [m for m in members if m["id"] != author_id]
	if not subscribers:
		return
	crm = get_crm(crm_id)
	obj = mochi.db.row("select class from objects where id=?", object_id)
	if not crm or not obj:
		return
	title = get_object_display(crm, obj, object_id)
	excerpt = content.strip()[:80]
	for sub in subscribers:
		name = sub.get("name")
		if name and ("@[" + name + "]").lower() in content_lower:
			mochi.message.send(
				{"from": crm_id, "to": sub["id"], "service": "crm", "event": "mention/notify"},
				{"object": object_id, "title": title, "excerpt": excerpt, "author": author_name}
			)

def mention_text(value, maximum):
	if type(value) != "string":
		return ""
	return value[:maximum]

def event_mention_notify(e):
	"""Subscriber receives a mention notification from a CRM owner."""
	crm_id = e.header("from")
	# Only for a CRM this user holds. Core authenticates "from" to an entity the
	# sender owns, so this drops mentions forged from a stranger's CRM.
	if not get_crm(crm_id):
		return
	title = mention_text(e.content("title"), 500)
	excerpt = mention_text(e.content("excerpt"), 200)
	# This handler runs on the recipient's host, so mochi.app.label resolves in
	# the recipient's own language.
	author = mention_text(e.content("author"), 255) or mochi.app.label("notifications.mention.author_unknown")
	object_id = e.content("object") or ""
	if object_id and not mochi.text.valid(str(object_id), "id"):
		object_id = ""
	# Build the link locally rather than trusting a sender-supplied url, so a
	# forged mention cannot carry an arbitrary target.
	fp = mochi.entity.fingerprint(crm_id)
	url = "/crm/" + fp + "/" + object_id if (fp and object_id) else ("/crm/" + fp if fp else "/crm")
	body = mochi.app.label("notifications.body.mentioned_you", author=author, excerpt=excerpt)
	notify("mention", crm_id, title, body, url, event_id="mention:" + (object_id or crm_id))

# Whether a move may promote the object in row (its id, class and parent, read
# under the move's lock) to the top level: one already there is left as it is,
# and one under a parent needs a class the hierarchy allows at the top level,
# as object/update requires for the same change. Reads go through handle.
def promotable(crm_id, row, handle):
	if not row["parent"]:
		return True
	return handle.exists("select 1 from hierarchy where crm=? and class=? and parent=''", crm_id, row["class"])

def would_create_cycle(object_id, new_parent_id, handle=None):
	"""Check if setting new_parent_id as parent of object_id would create a cycle."""
	if not new_parent_id:
		return False
	current = new_parent_id
	# Cap the walk like get_all_descendants: write-time guards keep the tree
	# acyclic, but a pre-existing cycle among unrelated ancestors would
	# otherwise spin to the Starlark timeout. Treat exhaustion as a cycle.
	for _ in range(100):
		if current == object_id:
			return True
		if not current:
			return False
		parent_row = (handle or mochi.db).row("select parent from objects where id=?", current)
		current = parent_row["parent"] if parent_row else ""
	return True

# Makes `parent` the parent of the object in `row` (its id, class and parent),
# for a move or an update by `user`: the change must not make a cycle, and the
# hierarchy must allow the object's class under the new parent's class, ""
# being the top level. The object and its descendants then take the new
# parent's board column and row values, so it shows among its new siblings.
# Answers an error label and status, or None once the parent is set or when it
# was that one already. The values written are added to changes, which the
# caller passes to values_broadcast after telling subscribers of the parent.
# Every read and write goes through handle, the caller's open transaction, each
# object it changes takes its version for the change from versions
# (version_take), and the activity entry's broadcast is added to events
# (log_activity).
def object_reparent(crm_id, row, parent, user, now, changes, versions, handle, events):
	object_id = row["id"]
	old_parent = row["parent"]
	if parent == old_parent:
		return None
	if parent and would_create_cycle(object_id, parent, handle):
		return ("errors.cannot_set_parent_would_create_a_cycle", 400)
	problem = hierarchy_check(crm_id, row["class"], parent, handle)
	if problem:
		return problem
	row_set("objects", "id=?", [object_id], {"parent": parent, "updated": now}, handle)
	version_take(versions, object_id, handle)
	log_activity(object_id, user, "moved", "parent", old_parent, parent, handle, events)
	if parent:
		parent_values = handle.rows('select field, value from "values" where object=?', parent) or []
		parent_val_map = {v["field"]: v["value"] for v in parent_values}
		views = handle.rows("select columns, rows from views where crm=?", crm_id) or []
		sync_fields = {}
		for view in views:
			if view["columns"]:
				sync_fields[view["columns"]] = parent_val_map.get(view["columns"], "")
			if view["rows"]:
				sync_fields[view["rows"]] = parent_val_map.get(view["rows"], "")
		values_cascade(crm_id, [object_id] + get_all_descendants(object_id, 0, handle), sync_fields, now, changes, versions, handle)
	return None

# hierarchy_check(crm_id, obj_class, parent, handle) -> an error label and
# status, or None when the hierarchy allows an object of obj_class under parent,
# "" being the top level, judged on the parent's class as handle reads it.
def hierarchy_check(crm_id, obj_class, parent, handle):
	parent_class = ""
	if parent:
		parent_row = handle.row("select class from objects where id=? and crm=?", parent, crm_id)
		if not parent_row:
			return ("errors.parent_object_not_found", 404)
		parent_class = parent_row["class"]
	if not handle.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, obj_class, parent_class):
		return ("errors.parent_hierarchy_disallowed", 400)
	return None

# children_check(crm_id, object_id, obj_class, handle) -> (key, code) or None:
# whether each of the object's children may stay under it once it is of
# obj_class, read through handle, the change's transaction. A class change must
# not leave children the hierarchy no longer allows under it.
def children_check(crm_id, object_id, obj_class, handle):
	for child in handle.rows("select distinct class from objects where crm=? and parent=?", crm_id, object_id) or []:
		if not handle.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, child["class"], obj_class):
			return ("errors.class_hierarchy_disallowed", 400)
	return None

# values_cascade(crm_id, ids, values, now, changes, versions, handle): give each
# object of ids those of values ({field: value}) its own class has the field for
# and accepts, and leave it the rest. Fields are per class, so a child of
# another class may lack the field, or not offer the option, its parent's move
# names. Each object whose values change is added to changes as {"id",
# "values", "updated", "version"}, its version for the change taken from
# versions (version_take). Every read and write goes through handle, the
# change's transaction.
def values_cascade(crm_id, ids, values, now, changes, versions, handle):
	accepted = {}
	for object_id in ids:
		row = handle.row("select class from objects where id=? and crm=?", object_id, crm_id)
		if not row:
			continue
		taken = {}
		for field, value in values.items():
			key = (row["class"], field)
			if key not in accepted:
				accepted[key] = handle.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, row["class"], field) and validate_field_value(crm_id, row["class"], field, value, handle) == None
			if not accepted[key]:
				continue
			current = handle.row("select value from \"values\" where object=? and field=?", object_id, field)
			if (current["value"] if current else "") == value:
				continue
			row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": value}, handle)
			taken[field] = value
		if taken:
			row_set("objects", "id=?", [object_id], {"updated": now}, handle)
			changes.append({"id": object_id, "values": taken, "updated": now, "version": version_take(versions, object_id, handle)})

# values_broadcast(crm_id, changes, user, events): add to events, for
# events_commit, the values/update events that tell subscribers the values
# values_cascade wrote, one per object, with the owner's time and the object's
# version. Marked sync, as the owner notifies no watcher of an object a cascade
# reached either.
def values_broadcast(crm_id, changes, user, events):
	for change in changes:
		events.append({"event": "values/update", "data": {
			"crm": crm_id, "id": change["id"], "updated": change["updated"],
			"values": change["values"], "user": user, "sync": True, "version": change["version"],
		}})

def get_all_descendants(object_id, depth=0, handle=None):
	"""Get all descendant object IDs recursively, through handle when one is
	given."""
	if depth >= 100:
		return []
	result = []
	children = (handle or mochi.db).rows("select id from objects where parent=?", object_id)
	for child in (children or []):
		result.append(child["id"])
		result.extend(get_all_descendants(child["id"], depth + 1, handle))
	return result

# tree_collect(query, root, scope, total) -> [root, then every row beneath it,
# breadth first, each once]: query names the children of one id (its two
# parameters the parent and scope), and total bounds how many there can be.
# Starlark has no while, and a list may not grow while it is iterated, so the
# walk steps an index through the list it builds.
def tree_collect(query, root, scope, total):
	order = [root]
	visited = {root: True}
	index = 0
	for _ in range(total + 1):
		if index >= len(order):
			break
		for child in mochi.db.rows(query, order[index], scope) or []:
			if child["id"] not in visited:
				visited[child["id"]] = True
				order.append(child["id"])
		index += 1
	return order

def delete_object_cascade(crm_id, object_id, user=""):
	"""Delete an object and every object beneath it in this CRM. The tree is
	collected first, each object once, then deleted children first: a chain of
	parents that loops back on itself is walked once rather than without end."""
	order = tree_collect("select id from objects where parent=? and crm=?", object_id, crm_id, mochi.db.row("select count(*) as n from objects where crm=?", crm_id)["n"])
	for id in reversed(order):
		attachment_clear(id)
		row_remove("watchers", "object=?", [id])
		mochi.db.execute("delete from activity where object=?", id)
		delete_object_comments(id, crm_id)
		row_remove("values", "object=?", [id])
		row_remove("links", "source=? or target=?", [id, id])
		row_remove("objects", "id=?", [id])
		# Broadcast delete event for each object
		broadcast_event(crm_id, "object/delete", {"crm": crm_id, "id": id, "user": user})

# Delete an object's attachments, or with kind "comment" a comment's. `preserve`
# keeps rows whose bytes live here (entity == ""): resync repair may drop
# references to files hosted elsewhere but must never destroy this replica's
# own uploads, which may be the only copy.
def prune_attachments(object_id, crm_id, preserve, kind="object"):
	kept = 0
	for att in (attachment_list(object_id, crm_id, kind) or []):
		if preserve and not att["entity"]:
			kept += 1
			continue
		attachment_delete(att["id"])
	if kept:
		mochi.log.debug("prune_attachments: kept " + str(kept) + " locally-stored attachment(s) for " + str(object_id))

def delete_object_local(crm_id, object_id, preserve=False):
	prune_attachments(object_id, crm_id, preserve)
	row_remove("watchers", "object=?", [object_id])
	mochi.db.execute("delete from activity where object=?", object_id)
	delete_object_comments(object_id, crm_id, preserve)
	row_remove("values", "object=?", [object_id])
	row_remove("links", "source=? or target=?", [object_id, object_id])
	row_remove("objects", "id=? and crm=?", [object_id, crm_id])

# object_replicate(crm_id, answer, obj_class, parent, title, title_field,
# user_id) writes the replica's copy of an object the owner has just created
# for this user, from the owner's answer, and returns whether it did. The owner
# names the id: one not in the shape mochi.uid() mints, or one naming a comment
# or another CRM's object, is refused, since the title and the watcher would
# otherwise land on that row. The canonical rank and timestamps are taken from
# the answer so every subscriber agrees on the order, reduced to their types; an
# old owner replying without them gets local now(). The values the owner stored
# with it are its answer's values, not the ones this server sent.
def object_replicate(crm_id, answer, obj_class, parent, title, title_field, user_id):
	if type(answer) != "dict":
		return False
	object_id = answer.get("id")
	if not identifier(object_id) or foreign_object(object_id, crm_id):
		return False
	now = mochi.time.now()
	version = owner_version(answer.get("version")) or 0
	if not mochi.db.exists("select 1 from objects where id=?", object_id):
		row_merge("objects", ["id"], {"id": object_id, "crm": crm_id, "class": obj_class, "parent": parent, "rank": rank_copy(answer.get("rank")), "created": safe_int(answer.get("created")) or now, "updated": safe_int(answer.get("updated")) or now, "version": version})
	# The create's broadcast, and a later change's, may have landed first: the
	# values of a copy past the answer's version then stand.
	if not mochi.db.exists("select 1 from objects where id=? and version>?", object_id, version):
		if title and title_field:
			row_merge("values", ["object", "field"], {"object": object_id, "field": title_field, "value": title})
		values = answer.get("values")
		if type(values) == "dict" and mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
			for field, value in values.items():
				if type(field) != "string" or type(value) != "string" or value_refused(crm_id, object_id, field, value):
					continue
				row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": value})
	# Auto-watch creator locally so subscriber gets notifications
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": user_id, "created": now})
	return True

# ============================================================================
# Object Actions
# ============================================================================

def action_object_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	# Get filter params
	class_filter = a.input("class")
	parent_filter = a.input("parent")

	# Build query
	query = "select o.id, o.crm, o.class, o.parent, o.rank, o.created, o.updated from objects o where o.crm=?"
	params = [crm_id]

	if class_filter:
		query += " and o.class=?"
		params.append(class_filter)

	if parent_filter:
		query += " and o.parent=?"
		params.append(parent_filter)

	query += " order by o.rank asc, o.created desc, o.id desc"

	rows = mochi.db.rows(query, *params) or []

	# Batch-fetch all values for the returned objects
	values_map = {}
	if rows:
		object_ids = [row["id"] for row in rows]
		all_values = rows_in("select object, field, value from \"values\" where object in (", object_ids, ")")
		for v in all_values:
			if v["object"] not in values_map:
				values_map[v["object"]] = {}
			values_map[v["object"]][v["field"]] = v["value"]

	objects = []
	for row in rows:
		objects.append({
			"id": row["id"],
			"crm": row["crm"],
			"class": row["class"],
			"parent": row["parent"],
			"rank": row["rank"],
			"created": row["created"],
			"updated": row["updated"],
			"values": values_map.get(row["id"], {}),
		})

	# Get watched object IDs for the local user
	watched = mochi.db.rows(
		"select w.object from watchers w join objects o on o.id=w.object where o.crm=? and w.user=?",
		crm_id, a.user.identity.id) or []

	return {"data": {"objects": objects, "watched": [w["object"] for w in watched]}}

def action_object_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	obj_class = a.input("class")
	parent = a.input("parent") or ""
	title = a.input("title") or ""

	# A JSON body's object arrives as its JSON text; a form sends the text.
	values, problem = create_values(a.input("values"))
	if problem:
		a.error.label(400, problem)
		return

	# Look up the title field for this class
	title_field_row = mochi.db.row("select title from classes where crm=? and id=?", crm_id, obj_class)
	title_field = title_field_row["title"] if title_field_row else ""

	if crm["owner"] != 1:
		result = forward_to_owner(a, crm_id, "object/create", {
			"crm": crm_id, "class": obj_class,
			"title": title, "parent": parent, "values": values,
		})
		if result and result.get("data"):
			if not object_replicate(crm_id, result["data"], obj_class, parent, title, title_field, a.user.identity.id):
				a.error.label(502, "errors.invalid_data")
				return
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	# The same helper a forwarded object/create reaches.
	created = do_object_create(crm_id, crm, {"class": obj_class, "parent": parent, "title": title, "values": values}, a.user.identity.id)
	if "error" in created:
		a.error.label(created.get("code", 500), created["error"], **(created.get("args") or {}))
		return

	return {"data": {
		"id": created["id"],
		"values": created["values"],
	}}

def action_object_get(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select * from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	# Get values
	values = {}
	value_rows = mochi.db.rows("select field, value from \"values\" where object=?", object_id) or []
	for v in value_rows:
		values[v["field"]] = v["value"]

	# Get links
	links = mochi.db.rows("select target, linktype, created from links where source=?", object_id) or []
	linked_by = mochi.db.rows("select source, linktype, created from links where target=?", object_id) or []

	# Check if user is watching
	watching = mochi.db.exists("select 1 from watchers where object=? and user=?", object_id, a.user.identity.id)

	# Clear notifications for this object if watching
	if watching:
		mochi.service.call("notifications", "clear/object", object_id)

	# Get comment count
	comment_row = mochi.db.row("select count(*) as count from comments where object=?", object_id)
	comment_count = comment_row["count"] if comment_row else 0

	return {"data": {
		"object": {
			"id": row["id"],
			"crm": row["crm"],
			"class": row["class"],
			"parent": row["parent"],
			"created": row["created"],
			"updated": row["updated"],
		},
		"values": values,
		"outgoing": links,
		"incoming": linked_by,
		"watching": watching,
		"comments": {"count": comment_count},
	}}

# object_update(crm_id, row, parent, new_class, user_id) -> the answer, or
# {"error", "code"}: give the object in row the parent (None keeps it) and class
# (None or "" keeps it) an update action or a forwarded one asks for. The
# object's id, class and parent are read again under the lock, since a move or
# an update beside this one may have changed them since row was read, and the
# hierarchy, whether anything changes and the activity's old values are judged
# on what it holds then. The hierarchy is judged on the class and parent the
# object ends with: a new class under the parent it keeps, or under the one it
# takes, which the reparent judges. The class is written first, so the
# reparent's cascade gives the object the values its new class holds. A new
# parent names no place among its children, so the object goes after the last
# of them, under the write lock that mints its key, with the values the
# reparent cascades, in one transaction; subscribers are told before it commits
# (events_commit). The answer names the parent, class and keys written, with
# the owner's time and the object's version for them (version_take), which the
# subscriber that forwarded the update writes.
def object_update(crm_id, row, parent, new_class, user_id):
	object_id = row["id"]
	now = mochi.time.now()
	changes = []
	events = []
	ranks = []
	versions = {}
	handle = rank_transaction(object_id)
	row = handle.row("select id, class, parent from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		handle.rollback()
		return {"error": "errors.object_not_found", "code": 404}
	target = new_class if new_class else row["class"]
	moved = parent != None and parent != row["parent"]
	if target != row["class"]:
		problem = None if moved else hierarchy_check(crm_id, target, row["parent"], handle)
		if problem and problem[1] == 400:
			problem = ("errors.class_hierarchy_disallowed", 400)
		if not problem:
			problem = children_check(crm_id, object_id, target, handle)
		if problem:
			handle.rollback()
			return {"error": problem[0], "code": problem[1]}
		row_set("objects", "id=?", [object_id], {"class": target}, handle)
		log_activity(object_id, user_id, "updated", "class", row["class"], target, handle, events)
	if moved:
		problem = object_reparent(crm_id, {"id": object_id, "class": target, "parent": row["parent"]}, parent, user_id, now, changes, versions, handle, events)
		if problem:
			handle.rollback()
			return {"error": problem[0], "code": problem[1]}
		key = rank_after_all(crm_id, object_id, handle)
		handle.execute("update objects set rank=? where id=?", key, object_id)
		ranks.append({"id": object_id, "rank": key, "updated": now})
	row_set("objects", "id=?", [object_id], {"updated": now}, handle)
	version = version_take(versions, object_id, handle)
	for r in ranks:
		r["version"] = version

	parent = parent if parent != None else row["parent"]
	events.append({"event": "object/update", "data": {
		"crm": crm_id, "id": object_id, "parent": parent, "class": target, "version": version,
		"user": user_id, "updated": now,
	}})
	# After the parent: a value names an object, which a subscriber pulls the
	# CRM for when it lacks one.
	values_broadcast(crm_id, changes, user_id, events)
	rank_broadcast(crm_id, ranks, now, user_id, events)
	events_commit(crm_id, events, handle)
	return {"success": True, "updated": now, "version": version, "parent": parent, "class": target, "ranks": ranks}

# update_answer(crm_id, object_id, answer, parent, new_class): write to this
# copy what the owner's answer to a forwarded update says it wrote, with the
# owner's time, so this copy's updated does not run ahead of the owner's next
# object/update. An answer carrying the object's version is written only past
# the copy's (answer_claim); one from an owner that predates versions, only
# when no older than the copy's time. An owner that predates naming the parent
# and class it wrote is taken to have written those asked for (parent and
# new_class). A class this copy does not hold yet, from a class event that has
# not landed, would fail the write's foreign key after the owner made the
# change, so it is left to a pull of the CRM, which brings both, put off past
# the request (resync_defer): a pull runs for up to SCHEMA_TIME, longer than a
# client waits.
def update_answer(crm_id, object_id, answer, parent, new_class):
	answer = answer if type(answer) == "dict" else {}
	now = owner_time(answer.get("updated")) or mochi.time.now()
	version = owner_version(answer.get("version"))
	if type(answer.get("parent")) == "string":
		parent = answer["parent"]
	if type(answer.get("class")) == "string":
		new_class = answer["class"]
	changes = {"updated": now}
	if parent != None:
		changes["parent"] = parent
	pull = False
	if new_class:
		if mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, new_class):
			changes["class"] = new_class
		else:
			pull = True
	handle = mochi.db.transaction()
	missing = False
	if version != None:
		# A class left to the pull leaves the copy short of the change, so its
		# version is not recorded and the broadcast still lands.
		if answer_claim(crm_id, object_id, version, not pull, handle):
			for r in sequence(answer.get("ranks")):
				if type(r) == "dict" and r.get("id") == object_id and rank_valid(r.get("rank")):
					changes["rank"] = r["rank"]
			row_set("objects", "id=? and crm=?", [object_id, crm_id], changes, handle)
	else:
		local = handle.row("select updated from objects where id=? and crm=?", object_id, crm_id)
		if not local or (local["updated"] or 0) > now:
			handle.rollback()
			if pull:
				resync_defer(crm_id, False, 0)
			return
		row_set("objects", "id=? and crm=?", [object_id, crm_id], changes, handle)
		missing = ranks_apply(crm_id, answer.get("ranks"), now, True, handle)[1]
	handle.commit()
	if pull or missing:
		resync_defer(crm_id, False, 0)

# answer_values(crm_id, object_id, values, handle): write the values an owner's
# answer names for object_id, each a string a field may hold (value_refused),
# through handle.
def answer_values(crm_id, object_id, values, handle):
	for field, value in values.items():
		if type(field) == "string" and type(value) == "string" and not value_refused(crm_id, object_id, field, value, handle):
			row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": value}, handle)

# answer_claim(crm_id, object_id, version, record, handle) -> whether this copy
# takes what an owner's answer to a forwarded change says it wrote of object_id
# at version: only when the copy's version is not past it, since a later
# change's broadcast may have landed first. At the version itself, one of the
# change's own events has landed, and the answer, the whole of what the change
# wrote of the object, brings what the others carry. With record, the copy
# keeps the version only when it is the next after its own: it then holds
# every change before it, where one still on its way would be dropped as
# older. An answer further ahead is written without it, and the broadcasts
# between bring the copy up to it. Reads and writes go through handle.
def answer_claim(crm_id, object_id, version, record, handle):
	local = handle.row("select version from objects where id=? and crm=?", object_id, crm_id)
	if not local or (local["version"] or 0) > version:
		return False
	if record and (local["version"] or 0) == version - 1:
		row_set("objects", "id=?", [object_id], {"version": version}, handle)
	return True

def action_object_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	object_id = a.input("object")

	if crm["owner"] != 1:
		params = {"crm": crm_id, "object": object_id}
		p = a.input("parent")
		if a.input("parent") != None:
			params["parent"] = p
		c = a.input("class")
		if c:
			params["class"] = c
		result = forward_to_owner(a, crm_id, "object/update", params)
		# Bound to this CRM: the owner's answer of success says nothing about an
		# id one of this user's other CRMs holds, which a write by id alone would
		# rewrite.
		if result and object_id and mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
			update_answer(crm_id, object_id, result.get("data"), p, c)
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select * from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	# Checked before any write, so a bad class refuses the whole update.
	new_class = a.input("class")
	if new_class and new_class != row["class"] and not mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, new_class):
		a.error.label(404, "errors.class_not_found")
		return

	answer = object_update(crm_id, row, a.input("parent"), new_class, a.user.identity.id)
	if answer.get("error"):
		a.error.label(answer["code"], answer["error"])
		return
	return {"data": answer}

def action_object_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	object_id = a.input("object")

	if crm["owner"] != 1:
		result = forward_to_owner(a, crm_id, "object/delete", {
			"crm": crm_id, "object": object_id,
		})
		# Bound to this CRM, as an update is: the owner's answer says nothing
		# about an object another of this user's CRMs holds.
		if result and object_id and mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
			# Attachments too. The owner's path clears them in
			# delete_object_cascade; this branch mirrors that cleanup by hand
			# and had every table but this one, so a subscriber's copy of the
			# object went away while its attachment rows and files stayed.
			attachment_clear(object_id)
			row_remove("values", "object=?", [object_id])
			row_remove("watchers", "object=?", [object_id])
			delete_object_comments(object_id, crm_id)
			row_remove("links", "source=? or target=?", [object_id, object_id])
			row_remove("objects", "id=?", [object_id])
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	# Cascade delete this object and all its children
	delete_object_cascade(crm_id, object_id, a.user.identity.id)

	return {"data": {"success": True}}

def action_object_move(a):
	"""Quick action to move object to a new status and/or rank (for drag-drop)."""

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	# int() on a non-integer aborts the handler with a 500, so validate the
	# rank up front for both the owner and forwarding branches below.
	if a.input("rank") != None and not mochi.text.valid(str(a.input("rank")), "integer"):
		a.error.label(400, "errors.invalid_value")
		return

	object_id = a.input("object")

	if crm["owner"] != 1:
		params = {
			"crm": crm_id, "object": object_id,
			"field": a.input("field") or "", "value": a.input("value"),
			"rank": a.input("rank"),
		}
		rf, rv = row_input(a.input("row"))
		if rf:
			params["row"] = {"field": rf, "value": rv}
		parent = a.input("parent")
		if parent != None:
			params["parent"] = parent
		sp = a.input("scope")
		if sp == None:
			sp = parent
		if sp != None:
			params["scope"] = sp
		for side in ["after", "before"]:
			if a.input(side):
				params[side] = a.input(side)
		if a.input("promote") == "true":
			params["promote"] = "true"
		clear = a.input("clear") == "true"
		if clear:
			params["clear"] = "true"
		result = forward_to_owner(a, crm_id, "object/move", params)
		if result and object_id and mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
			move_answer(crm_id, object_id, result.get("data"))
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id, class, parent from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	field = a.input("field") or ""
	value = a.input("value")  # New column value
	# A drop on the column for no value clears the field: an empty value
	# keeps it, as a reorder sends.
	clear = a.input("clear") == "true"
	row_field, row_value = row_input(a.input("row"))

	# A drop into another parent's children at a position: the new parent and
	# the place among its children go in one move, not an update and then a
	# move. A promote is the same change to the top level, so not both.
	parent = a.input("parent")
	if parent != None and a.input("promote") == "true":
		a.error.label(400, "errors.invalid_value")
		return

	answer = object_move(crm_id, row, {
		"field": field, "value": value, "clear": clear, "lane": row_field, "row": row_value,
		"parent": parent, "promote": a.input("promote") == "true", "scope": a.input("scope"),
		"after": a.input("after"), "before": a.input("before"), "rank": a.input("rank"),
	}, a.user.identity.id)
	if answer.get("error"):
		a.error.label(answer["code"], answer["error"], **(answer.get("args") or {}))
		return
	return {"data": answer}

# object_move(crm_id, row, move, user_id, notify=False) -> the answer, or
# {"error", "code", "args"}: move the object row names (its id) as a move action
# or a forwarded one asks. move holds the field and value of the column it goes
# into (clear empties it, an empty value keeps it), its lane as lane and row,
# the parent it goes under (None keeps it) or promote to the top level, and its
# place (move_rank): after and before, the objects it was dropped between, or
# rank, a position within scope, which is the parent when none is named. The
# object's id, class and parent are read again under the lock, since a move or
# an update beside this one may have changed them since row was read, and the
# promote's hierarchy, every value the move writes (move_check), whether the
# parent changes and the activity's old values are judged on what it holds
# then, before anything is written. The parent, the values, the lane and the
# keys are written in one transaction, under the write lock its keys are minted
# under, so a failure leaves no change subscribers are not told of; they are
# told before it commits (events_commit). notify tells the owner when watching,
# once it has. The answer names
# the parent and values the move wrote and every key, with the owner's time and
# the object's version for the move (version_take).
def object_move(crm_id, row, move, user_id, notify=False):
	object_id = row["id"]
	field = move["field"]
	parent = move["parent"]
	scope = move["scope"] if move["scope"] != None else parent
	now = mochi.time.now()
	changes = []
	events = []
	handle = rank_transaction(object_id)
	versions = {}
	row = handle.row("select id, class, parent from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		handle.rollback()
		return {"error": "errors.object_not_found", "code": 404}
	if move["promote"] and not promotable(crm_id, row, handle):
		handle.rollback()
		return {"error": "errors.parent_hierarchy_disallowed", "code": 400}
	invalid = move_check(crm_id, row["class"], field, move["value"], move["lane"], move["row"], move["clear"], handle) or move_place_check(object_id, move["after"], move["before"])
	if invalid:
		handle.rollback()
		return {"error": invalid["key"], "args": invalid.get("args"), "code": 400}
	parent_changed = False
	if parent != None:
		problem = object_reparent(crm_id, row, parent, user_id, now, changes, versions, handle, events)
		if problem:
			handle.rollback()
			return {"error": problem[0], "code": problem[1]}
		parent_changed = parent != row["parent"]

	# The value it moves into: none for a clear, the one sent, or its own, which
	# the reparent above may have given it.
	current = handle.row("select value from \"values\" where object=? and field=?", object_id, field)
	old_value = current["value"] if current else ""
	target_value = "" if move["clear"] else (move["value"] if move["value"] else old_value)
	value_changed = old_value != target_value
	if value_changed:
		row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": target_value}, handle)
		log_activity(object_id, user_id, "updated", field, old_value, target_value, handle, events)

	# The lane, for a drop in a board's swimlane
	lane = move["lane"]
	lane_changed = False
	if lane:
		current = handle.row("select value from \"values\" where object=? and field=?", object_id, lane)
		old_lane = current["value"] if current else ""
		if old_lane != move["row"]:
			row_merge("values", ["object", "field"], {"object": object_id, "field": lane, "value": move["row"]}, handle)
			log_activity(object_id, user_id, "updated", lane, old_lane, move["row"], handle, events)
			lane_changed = True

	# A promote clears the parent, for a child dragged to a column or lane
	if move["promote"]:
		current = handle.row("select parent from objects where id=?", object_id)
		old_parent = current["parent"] if current else ""
		if old_parent:
			row_set("objects", "id=?", [object_id], {"parent": ""}, handle)
			log_activity(object_id, user_id, "moved", "parent", old_parent, "", handle, events)
			parent = ""
			parent_changed = True

	ranks = move_rank(crm_id, object_id, {
		"field": field, "value": target_value, "lane": lane, "row": move["row"], "parent": scope, "class": row["class"],
	}, {"after": move["after"], "before": move["before"], "rank": move["rank"]}, value_changed, versions, handle)

	# Cascade the column and lane to the descendants that take them
	updated_values = {}
	if value_changed:
		updated_values[field] = target_value
	if lane_changed:
		updated_values[lane] = move["row"]
	if updated_values:
		values_cascade(crm_id, get_all_descendants(object_id, 0, handle), updated_values, now, changes, versions, handle)
	row_set("objects", "id=?", [object_id], {"updated": now}, handle)
	# A move counts as a change of the object whatever it wrote, as its time
	# moves on.
	version = version_take(versions, object_id, handle)
	final = handle.row("select parent from objects where id=?", object_id)

	# Subscribers learn a new parent the way object/update tells them of one.
	if parent_changed:
		events.append({"event": "object/update", "data": {
			"crm": crm_id, "id": object_id, "parent": final["parent"],
			"class": row["class"], "user": user_id, "updated": now, "version": version,
		}})
	values_broadcast(crm_id, changes, user_id, events)
	if updated_values:
		events.append({"event": "values/update", "data": {
			"crm": crm_id, "id": object_id, "updated": now,
			"values": updated_values, "user": user_id, "version": version,
		}})
	# The keys the move wrote: the moved object's, with the time it changed, and
	# any a tied neighbour or a spread took.
	for r in ranks:
		if r["id"] == object_id:
			r["updated"] = now
	rank_broadcast(crm_id, ranks, now, user_id, events)
	events_commit(crm_id, events, handle)
	if updated_values and notify:
		notify_watchers(object_id, crm_id, get_owner_identity(crm_id), user_id, mochi.app.label("notifications.body.updated"))

	# The values the move wrote on the object, those its new parent gave it
	# first, for the subscriber that forwarded it to write as they are.
	written = {}
	for change in changes:
		if change["id"] == object_id:
			written.update(change["values"])
	if field:
		written[field] = target_value
	if lane:
		written[lane] = move["row"]
	return {"success": True, "ranks": ranks, "updated": now, "parent": final["parent"], "values": written, "version": version}

# move_answer(crm_id, object_id, answer): write to this copy what the owner's
# answer to a forwarded move says it wrote: the object's parent and values and
# every key, with the owner's time, so this copy's updated does not run ahead of
# the owner's next object/update. With the object's version, each object is
# written only past the copy's version for it (answer_claim, and ranks_apply
# for the keys of the others); from an owner that predates versions, only when
# the answer is no older than the copy's time. An owner that predates naming
# the parent and values it wrote may not have written those asked for, so
# nothing is written: its broadcasts bring the move.
def move_answer(crm_id, object_id, answer):
	answer = answer if type(answer) == "dict" else {}
	now = owner_time(answer.get("updated"))
	if not now or type(answer.get("parent")) != "string" or type(answer.get("values")) != "dict":
		return
	version = owner_version(answer.get("version"))
	handle = mochi.db.transaction()
	if version != None:
		ranks = []
		changes = {"parent": answer["parent"], "updated": now}
		for r in sequence(answer.get("ranks")):
			if type(r) == "dict" and r.get("id") == object_id:
				if rank_valid(r.get("rank")):
					changes["rank"] = r["rank"]
			else:
				ranks.append(r)
		if answer_claim(crm_id, object_id, version, True, handle):
			answer_values(crm_id, object_id, answer["values"], handle)
			row_set("objects", "id=? and crm=?", [object_id, crm_id], changes, handle)
	else:
		ranks = answer.get("ranks")
		local = handle.row("select updated from objects where id=? and crm=?", object_id, crm_id)
		if local and (local["updated"] or 0) <= now:
			answer_values(crm_id, object_id, answer["values"], handle)
			row_set("objects", "id=? and crm=?", [object_id, crm_id], {"parent": answer["parent"], "updated": now}, handle)
	# The keys the owner wrote, any it untied or spread, so this copy orders the
	# objects as the owner does.
	missing = ranks_apply(crm_id, ranks, now, True, handle)[1]
	handle.commit()
	if missing:
		resync_defer(crm_id, False, 0)

# ============================================================================
# Value Actions
# ============================================================================

# values_submitted(a, fields) -> {field: value}: the field values a values/set
# request carries. Route parameters share a.input's namespace and win over a
# missing body key, so a field whose id is "object" or "crm" used to read the
# route's value and store it. Only the request's own keys count: the JSON body
# when there is one, else the form or query.
def values_submitted(a, fields):
	values = {}
	body = json.decode(a.body, None) if a.body else None
	if type(body) == "dict":
		for field_id in fields:
			if field_id in body and body[field_id] != None:
				values[field_id] = str(body[field_id])
		return values
	for field_id in fields:
		items = a.inputs(field_id)
		if items:
			values[field_id] = items[0]
	return values

def action_values_set(a):
	"""Set multiple field values at once."""

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id, class from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	# Get valid fields for this class
	valid_fields = {}
	field_types = {}
	field_rows = mochi.db.rows("select id, name, fieldtype from fields where crm=? and class=?", crm_id, row["class"]) or []
	for f in field_rows:
		valid_fields[f["id"]] = f["name"]
		field_types[f["id"]] = f["fieldtype"]

	if crm["owner"] != 1:
		values = values_submitted(a, valid_fields)
		result = forward_to_owner(a, crm_id, "values/set", {
			"crm": crm_id, "object": object_id, "values": values,
		})
		if result:
			values_answer(crm_id, object_id, result.get("data"), values)
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	# Every value the request carries is checked before any is written, so a
	# refusal writes none.
	values = {}
	for field_id, new_value in values_submitted(a, valid_fields).items():
		if len(str(new_value)) > 50000:
			a.error.label(400, "errors.value_too_long")
			return
		invalid = validate_field_value(crm_id, row["class"], field_id, new_value)
		if invalid:
			a.error.label(400, invalid["key"], **(invalid.get("args") or {}))
			return
		values[field_id] = str(new_value)

	written, _, now = values_write(crm_id, object_id, values, a.user.identity.id)
	values_watch(object_id, written, field_types, now)
	return {"data": {"success": True, "changed": list(written)}}

def action_value_set(a):
	"""Set a single field value."""

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		result = forward_to_owner(a, crm_id, "value/set", {
			"crm": crm_id, "object": a.input("object"),
			"field": a.input("field"), "value": a.input("value") or "",
		})
		# Update local cache so subsequent reads reflect the change, for an
		# object this CRM holds: the owner's answer says nothing of another's.
		if result and mochi.db.exists("select 1 from objects where id=? and crm=?", a.input("object"), crm_id):
			values_answer(crm_id, a.input("object"), result.get("data"), {a.input("field"): a.input("value") or ""})
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	field_id = a.input("field")
	if not field_id:
		a.error.label(400, "errors.field_id_required")
		return

	row = mochi.db.row("select id, class from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	# Verify field exists for this class
	field_row = mochi.db.row("select id, fieldtype from fields where crm=? and class=? and id=?", crm_id, row["class"], field_id)
	if not field_row:
		a.error.label(400, "errors.invalid_field_for_this_class")
		return

	new_value = a.input("value") or ""
	if len(new_value) > 50000:
		a.error.label(400, "errors.value_too_long")
		return

	invalid = validate_field_value(crm_id, row["class"], field_id, new_value)
	if invalid:
		a.error.label(400, invalid["key"], **(invalid.get("args") or {}))
		return

	written, _, now = values_write(crm_id, object_id, {field_id: str(new_value)}, a.user.identity.id)
	values_watch(object_id, written, {field_id: field_row["fieldtype"]}, now)
	return {"data": {"success": True}}

# values_write(crm_id, object_id, values, user_id) -> (written, version, now):
# write values ({field: value}, each checked already) to the object in one
# transaction, logging each that changes and raising the object's version once
# for the change (version_take); subscribers are told before it commits
# (events_commit), in one values/update with the owner's time and the version.
# written holds the values that changed, and version is None when none did.
def values_write(crm_id, object_id, values, user_id):
	now = mochi.time.now()
	events = []
	written = {}
	version = None
	handle = mochi.db.transaction()
	for field, value in values.items():
		old = handle.row("select value from \"values\" where object=? and field=?", object_id, field)
		old_value = old["value"] if old else ""
		if value == old_value:
			continue
		row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": value}, handle)
		log_activity(object_id, user_id, "updated", field, old_value, value, handle, events)
		written[field] = value
	if written:
		row_set("objects", "id=?", [object_id], {"updated": now}, handle)
		version = version_take({}, object_id, handle)
		events.append({"event": "values/update", "data": {
			"crm": crm_id, "id": object_id, "values": written,
			"user": user_id, "updated": now, "version": version,
		}})
	events_commit(crm_id, events, handle)
	return written, version, now

# values_watch(object_id, written, types, now): have each user a value set
# assigns, in a user field ({field: fieldtype} in types), watch the object.
def values_watch(object_id, written, types, now):
	for field, value in written.items():
		if types.get(field) == "user" and value:
			row_merge("watchers", ["object", "user"], {"object": object_id, "user": value, "created": now})

# values_answer(crm_id, object_id, answer, sent): write to this copy what the
# owner's answer to a forwarded value set says it wrote, past the copy's
# version for the object (answer_claim) with the owner's time. An owner that
# predates naming them is taken to have written the values sent.
def values_answer(crm_id, object_id, answer, sent):
	answer = answer if type(answer) == "dict" else {}
	written = answer.get("values")
	if type(written) != "dict":
		for field, value in sent.items():
			row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": value})
		return
	version = owner_version(answer.get("version"))
	if version == None:
		return
	handle = mochi.db.transaction()
	if answer_claim(crm_id, object_id, version, True, handle):
		answer_values(crm_id, object_id, written, handle)
		updated = owner_time(answer.get("updated"))
		if updated:
			row_set("objects", "id=?", [object_id], {"updated": updated}, handle)
	handle.commit()

# ============================================================================
# Link Actions
# ============================================================================

def action_link_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	# Get outgoing links
	outgoing = mochi.db.rows("""
		select l.target, l.linktype, l.created, o.class, v.value as title
		from links l
		join objects o on o.id = l.target
		left join classes c on c.crm = o.crm and c.id = o.class
		left join "values" v on v.object = l.target and v.field = c.title
		where l.source=?
	""", object_id) or []

	# Get incoming links
	incoming = mochi.db.rows("""
		select l.source, l.linktype, l.created, o.class, v.value as title
		from links l
		join objects o on o.id = l.source
		left join classes c on c.crm = o.crm and c.id = o.class
		left join "values" v on v.object = l.source and v.field = c.title
		where l.target=?
	""", object_id) or []

	return {"data": {"outgoing": outgoing, "incoming": incoming}}

def action_link_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "link/create", {
			"crm": crm_id, "object": a.input("object"),
			"target": a.input("target"), "linktype": a.input("linktype"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	target_id = a.input("target")
	if not target_id:
		a.error.label(400, "errors.target_object_is_required")
		return

	linktype = a.input("linktype")
	if not linktype:
		a.error.label(400, "errors.link_type_is_required")
		return

	if linktype not in ["blocks", "relates", "duplicates"]:
		a.error.label(400, "errors.invalid_link_type")
		return

	# Verify both objects exist in same crm
	source_row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	target_row = mochi.db.row("select id from objects where id=? and crm=?", target_id, crm_id)

	if not source_row or not target_row:
		a.error.label(404, "errors.object_not_found")
		return

	if object_id == target_id:
		a.error.label(400, "errors.cannot_link_object_to_itself")
		return

	# Check if link already exists
	existing = mochi.db.exists("select 1 from links where source=? and target=? and linktype=?", object_id, target_id, linktype)
	if existing:
		a.error.label(400, "errors.link_already_exists")
		return

	now = mochi.time.now()
	row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": object_id, "target": target_id, "linktype": linktype, "created": now})

	log_activity(object_id, a.user.identity.id, "linked", linktype, "", target_id)

	broadcast_event(crm_id, "link/create", {
		"crm": crm_id, "source": object_id,
		"target": target_id, "linktype": linktype, "created": now,
		"user": a.user.identity.id
	})

	return {"data": {"success": True}}

def action_link_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "link/delete", {
			"crm": crm_id, "object": a.input("object"),
			"target": a.input("target"), "linktype": a.input("linktype"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	object_id = a.input("object")
	target_id = a.input("target")
	linktype = a.input("linktype")

	if not object_id or not target_id or not linktype:
		a.error.label(400, "errors.object_target_and_linktype_are_required")
		return

	if linktype not in ["blocks", "relates", "duplicates"]:
		a.error.label(400, "errors.invalid_link_type")
		return

	row_remove("links", "crm=? and source=? and target=? and linktype=?", [crm_id, object_id, target_id, linktype])
	broadcast_event(crm_id, "link/delete", {
		"crm": crm_id, "source": object_id,
		"target": target_id, "linktype": linktype, "user": a.user.identity.id
	})

	return {"data": {"success": True}}

# Build a recursive comment tree for an object
def object_comments(crm_id, object_id, parent_id, depth):
	"""Nested comments for an object.

	One query for every comment on the object and one for all of their
	attachments, then the tree is assembled in memory. The recursive form
	cost one query per comment per level, plus an attachment query per
	comment."""
	rows = mochi.db.rows(
		"select id, parent, author, name, content, created, edited from comments where object=? order by created desc",
		object_id
	) or []
	attachments = attachments_many([row["id"] for row in rows], crm_id, "comment")
	children = {}
	for row in rows:
		key = row["parent"] or ""
		children[key] = children.get(key, []) + [row]
		row["attachments"] = attachments.get(row["id"], [])
	return comment_tree(children, parent_id or "", depth)

def comment_tree(children, parent_id, depth):
	if depth > 100:
		return []
	out = []
	for row in children.get(parent_id, []):
		row["children"] = comment_tree(children, row["id"], depth + 1)
		out.append(row)
	return out

# Delete a comment and every reply beneath it, with their attachments. The
# thread is collected first, each comment once, so a chain of parents a peer
# made loop is walked once rather than without end.
def delete_comment_tree(comment_id, crm_id):
	# Only ever touch a comment whose object is in this crm - guards every caller
	# (event_comment_delete, do_comment_delete) against a cross-crm comment id or
	# a cross-crm parent pointer dragging another crm's comments into the delete.
	# Replies are those on the same object.
	row = mochi.db.row("select c.object as object from comments c join objects o on c.object=o.id where c.id=? and o.crm=?", comment_id, crm_id)
	if not row:
		return
	order = tree_collect("select id from comments where parent=? and object=?", comment_id, row["object"], mochi.db.row("select count(*) as n from comments where object=?", row["object"])["n"])
	for id in reversed(order):
		for att in (attachment_list(id, crm_id, "comment") or []):
			attachment_delete(att["id"])
		row_remove("comments", "id=?", [id])
# Delete all comments and their attachments for an object
def delete_object_comments(object_id, crm_id, preserve=False):
	comments = mochi.db.rows("select id from comments where object=?", object_id) or []
	for c in comments:
		prune_attachments(c["id"], crm_id, preserve, "comment")
	row_remove("comments", "object=?", [object_id])
# Delete all comment attachments for all objects in a crm
def delete_crm_comment_attachments(crm_id):
	comments = mochi.db.rows(
		"select c.id from comments c join objects o on c.object=o.id where o.crm=?", crm_id
	) or []
	for c in comments:
		for att in (attachment_list(c["id"], crm_id, "comment") or []):
			attachment_delete(att["id"])

# ============================================================================
# Person asset proxy (avatar, banner, favicon, style, information)
# ============================================================================

def asset_crm(a):
	"""Resolve the routed CRM for a public asset route, or None to refuse.

	The access check takes an explicit user id because these routes are reached
	anonymously, and the owner test mirrors require_crm: a subscriber holds no
	mochi.access rows for a remote CRM, so checking access there refuses every
	subscribed CRM outright."""
	crm_id = resolve_crm(a)
	if not crm_id:
		return None
	crm = get_crm(crm_id)
	if not crm:
		return None
	if crm["owner"] != 1:
		# A replica lives in the subscriber's own database, so a signed-in caller
		# reaching it is its holder. An anonymous request arrives through a hosted
		# domain, in the route owner's database, where it would otherwise see
		# every private crm that user subscribes to.
		return crm_id if a.user else None
	user_id = a.user.identity.id if a.user and a.user.identity else None
	if not check_crm_access(user_id, crm_id, "view"):
		return None
	return crm_id

_PERSON_ASSETS = ("avatar", "banner", "favicon", "style", "information")

def action_comment_asset(a):
	asset = a.input("asset")
	if asset not in _PERSON_ASSETS:
		a.error.label(404, "errors.unknown_asset")
		return
	crm_id = asset_crm(a)
	if not crm_id:
		a.error.label(403, "errors.access_denied")
		return
	# Bind the comment to the route crm (via its object) so this can't resolve a
	# comment author in a crm the URL doesn't name.
	row = mochi.db.row("select c.author from comments c join objects o on c.object=o.id where c.id=? and o.crm=?", a.input("comment"), crm_id)
	# attachment-ok: asset_crm checks view access (a signed-in holder for a replica), and the comment is bound to the routed crm
	return asset_serve(a, row["author"] if row else "", "people", asset)

def action_activity_asset(a):
	asset = a.input("asset")
	if asset not in _PERSON_ASSETS:
		a.error.label(404, "errors.unknown_asset")
		return
	crm_id = asset_crm(a)
	if not crm_id:
		a.error.label(403, "errors.access_denied")
		return
	# Bind the activity to the route crm (via its object).
	row = mochi.db.row("select a2.user from activity a2 join objects o on a2.object=o.id where a2.id=? and o.crm=?", a.input("activity"), crm_id)
	# attachment-ok: asset_crm checks view access (a signed-in holder for a replica), and the activity is bound to the routed crm
	return asset_serve(a, row["user"] if row else "", "people", asset)

def action_user_asset(a):
	asset = a.input("asset")
	if asset not in _PERSON_ASSETS:
		a.error.label(404, "errors.unknown_asset")
		return
	crm_id = asset_crm(a)
	if not crm_id:
		a.error.label(403, "errors.access_denied")
		return
	# Bind the subject to someone who appears in the routed crm, as the comment and
	# activity variants do: the route is public, so an unchecked id would relay any
	# entity's stream to anyone with "*" view access.
	subject = a.input("user") or ""
	if not subject:
		a.error.label(404, "errors.unknown_asset")
		return
	# Membership only. activity.user and comments.author are both written
	# verbatim from an uploaded backup by action_data_import, so testing those
	# would let a design-access user seed any entity id and have this public
	# route proxy that entity's people assets.
	known = mochi.db.exists("select 1 from subscribers where crm=? and id=?", crm_id, subject)
	if not known:
		a.error.label(404, "errors.unknown_asset")
		return
	# attachment-ok: asset_crm checks view access (a signed-in holder for a replica), and the subject must subscribe to the routed crm
	return asset_serve(a, subject, "people", asset)

# ============================================================================
# Comment Actions
# ============================================================================

def action_comment_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	comments = object_comments(crm_id, object_id, "", 0)
	count_row = mochi.db.row("select count(*) as count from comments where object=?", object_id)
	count = count_row["count"] if count_row else 0

	return {"data": {"comments": comments, "count": count}}

def action_comment_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	object_id = a.input("object")
	content = a.input("content")
	parent = a.input("parent") or ""

	if not content or not content.strip():
		a.error.label(400, "errors.content_is_required")
		return
	if len(content) > 50000:
		a.error.label(400, "errors.content_too_long")
		return

	if crm["owner"] != 1:
		if not object_id:
			a.error.label(400, "errors.object_id_required")
			return
		if not mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id):
			a.error.label(404, "errors.object_not_found")
			return
		comment_id = mochi.uid()
		now = mochi.time.now()
		# Save locally for optimistic UI
		row_merge("comments", ["id"], {"id": comment_id, "object": object_id, "parent": parent, "author": a.user.identity.id, "name": a.user.identity.name, "content": content.strip(), "created": now, "edited": 0})
		# Save attachments locally
		attachments = attachment_save(a, comment_id, kind="comment")
		# Fire-and-forget to crm owner with attachment metadata
		submit_data = {"id": comment_id, "object": object_id, "parent": parent,
			 "content": content.strip(), "name": a.user.identity.name}
		if attachments:
			submit_data["attachments"] = [{"id": att["id"], "name": att["name"], "size": att["size"], "content_type": att.get("type", ""), "rank": att.get("rank", 0), "created": att.get("created", now)} for att in attachments]
		mochi.message.send(
			{"from": a.user.identity.id, "to": crm_id, "service": "crm", "event": "comment/submit"},
			submit_data
		)
		# Auto-watch commenter locally so subscriber gets notifications
		row_merge("watchers", ["object", "user"], {"object": object_id, "user": a.user.identity.id, "created": now})
		return {"data": {
			"id": comment_id, "parent": parent,
			"author": a.user.identity.id, "name": a.user.identity.name,
			"content": content.strip(), "created": now, "edited": 0,
			"children": [], "attachments": attachment_list(comment_id, crm_id, "comment") or [],
		}}

	if not check_crm_access(a.user.identity.id, crm_id, "comment"):
		a.error.label(403, "errors.access_denied")
		return

	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	if not content or not content.strip():
		a.error.label(400, "errors.content_is_required")
		return

	if parent:
		if not mochi.db.row("select id from comments where id=? and object=?", parent, object_id):
			a.error.label(404, "errors.parent_comment_not_found")
			return

	comment_id = mochi.uid()
	now = mochi.time.now()

	row_merge("comments", ["id"], {"id": comment_id, "object": object_id, "parent": parent, "author": a.user.identity.id, "name": a.user.identity.name, "content": content.strip(), "created": now, "edited": 0})

	attachments = attachment_save(a, comment_id, kind="comment") or []

	row_set("objects", "id=?", [object_id], {"updated": now})
	log_activity(object_id, a.user.identity.id, "commented")

	# Auto-watch on comment
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": a.user.identity.id, "created": now})

	# Broadcast with attachment metadata
	comment_event = {
		"crm": crm_id, "object": object_id,
		"id": comment_id, "parent": parent,
		"author": a.user.identity.id, "name": a.user.identity.name,
		"content": content.strip(), "created": now, "user": a.user.identity.id
	}
	if attachments:
		comment_event["attachments"] = [{"id": att["id"], "name": att["name"], "size": att["size"], "content_type": att.get("type", ""), "rank": att.get("rank", 0), "created": att.get("created", now)} for att in attachments]
	broadcast_event(crm_id, "comment/create", comment_event)
	notify_mentions(object_id, crm_id, content, a.user.identity.id, a.user.identity.name)

	return {"data": {
		"id": comment_id, "parent": parent,
		"author": a.user.identity.id, "name": a.user.identity.name,
		"content": content.strip(), "created": now, "edited": 0,
		"children": [], "attachments": attachments,
	}}

def action_comment_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	object_id = a.input("object")
	comment_id = a.input("comment")
	content = a.input("content")

	if content and len(content) > 50000:
		a.error.label(400, "errors.content_too_long")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "comment/update", {
			"crm": crm_id, "object": object_id,
			"comment": comment_id, "content": content,
		})

	if not check_crm_access(a.user.identity.id, crm_id, "comment"):
		a.error.label(403, "errors.access_denied")
		return

	if not object_id or not comment_id:
		a.error.label(400, "errors.object_and_comment_id_required")
		return

	# The object must belong to the CRM access was checked against: binding the
	# comment to the object alone lets the pair name another crm, so a caller could
	# edit comments anywhere and the broadcast would go to the wrong crm.
	# comment/create binds the same way.
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		a.error.label(404, "errors.object_not_found")
		return

	comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
	if not comment:
		a.error.label(404, "errors.comment_not_found")
		return

	# Only author can edit
	if comment["author"] != a.user.identity.id:
		a.error.label(403, "errors.cannot_edit_others_comment")
		return

	if not content or not content.strip():
		a.error.label(400, "errors.content_is_required")
		return

	now = mochi.time.now()
	row_set("comments", "id=?", [comment_id], {"content": content.strip(), "edited": now})
	broadcast_event(crm_id, "comment/update", {
		"crm": crm_id, "object": object_id,
		"id": comment_id, "content": content.strip(), "edited": now,
		"user": a.user.identity.id
	})

	return {"data": {"success": True}}

def action_comment_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	object_id = a.input("object")
	comment_id = a.input("comment")

	if crm["owner"] != 1:
		result = forward_to_owner(a, crm_id, "comment/delete", {
			"crm": crm_id, "object": object_id,
			"comment": comment_id,
		}, handled=["errors.comment_not_found"])
		if result and result.get("error") == "errors.comment_not_found":
			# The owner has no such comment. A local copy by this user is a phantom (an
			# optimistic write whose submit never arrived) that no remote delete can ever
			# clear, so delete it locally (#466): one on an object of this CRM, not
			# of another of this user's.
			comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
			if comment and comment["author"] == a.user.identity.id and mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
				delete_comment_tree(comment_id, crm_id)
				return {"data": {"success": True}}
			a.error.label(404, "errors.comment_not_found")
			return
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "comment"):
		a.error.label(403, "errors.access_denied")
		return

	if not object_id or not comment_id:
		a.error.label(400, "errors.object_and_comment_id_required")
		return

	# Same binding as above: the object must be in the routed crm.
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		a.error.label(404, "errors.object_not_found")
		return

	comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
	if not comment:
		a.error.label(404, "errors.comment_not_found")
		return

	# Only author can delete
	if comment["author"] != a.user.identity.id:
		a.error.label(403, "errors.cannot_delete_another_user_s_comment")
		return

	delete_comment_tree(comment_id, crm_id)

	broadcast_event(crm_id, "comment/delete", {
		"crm": crm_id, "object": object_id, "id": comment_id,
		"user": a.user.identity.id
	})

	return {"data": {"success": True}}

# ============================================================================
# Attachment Actions
# ============================================================================

# Attachment routes. attachment_serve performs no access check of its own, so
# this handler is the gate: require_crm enforces view access, and the attachment
# must belong to an object or comment in THIS CRM.
def action_attachment(a):
	serve_attachment(a, "")

def action_attachment_thumbnail(a):
	serve_attachment(a, "thumbnail")

def action_attachment_preview(a):
	serve_attachment(a, "preview")

def serve_attachment(a, variant):
	crm_id, crm = require_crm(a, "view")
	if not crm_id:
		return
	attachment = a.input("id")

	# The binding runs for owned AND subscribed CRMs. Never defer to the owner
	# enforcing access on pull: a subscriber whose access was revoked would keep
	# its cached copy reachable.
	def in_crm(object, kind):
		return container_in_crm(object, kind, crm_id)

	# The owner adopts legacy remote-provenance rows on first serve, taking
	# the bytes in so the CRM's canonical host serves its own file from then
	# on; subscribers keep pulling to cache.
	attachment_serve(a, attachment, crm_id, variant=variant, member=in_crm,
		adopt=crm.get("owner") == 1)

# P2P byte-pull responder. A subscriber stores an object's attachment metadata
# (entity = the CRM), then pulls the bytes from the owner here on demand.
def event_attachment_fetch(e):
	# `to` is routing only - the entity the puller dialled to reach these
	# bytes. For a subscriber-held upload that is this user's own identity,
	# not a CRM, so the container comes from the requested row: the
	# attachment's object or comment, as its kind says, resolved to the CRM it
	# belongs to here.
	id = e.content("id")
	crm_id = ""
	if attachment_identifier(id):
		row = attachment_row(id)
		if row:
			if row.get("kind") == "comment":
				owner = mochi.db.row("select o.crm from comments c join objects o on o.id=c.object where c.id=?", row["object"])
			else:
				owner = mochi.db.row("select crm from objects where id=?", row["object"])
			if owner:
				crm_id = owner["crm"]

	def in_crm(object, kind):
		return container_in_crm(object, kind, crm_id)

	# The CRM's own entity may always fetch bytes bound to it - that is the
	# owner taking a subscriber's upload in (attachment_accept / adopt).
	attachment_respond(e, crm_id,
		lambda sender, container: sender == container or check_crm_access(sender, container, "view"),
		member=in_crm)

# Attachment pushed by a subscriber: the bytes arrive with the metadata, are
# stored as our own, and the metadata fans out. Replaces attachment/submit's
# metadata-only flow, which left the owner holding references it could not
# reliably serve (#484); that handler stays for subscribers not yet upgraded.
def event_attachment_push(e):
	crm_id = e.header("to")
	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		e.write({"status": "404"})
		return
	sender = e.header("from")
	if not sender or not check_crm_access(sender, crm_id, "write"):
		e.write({"status": "403"})
		return
	object_id = e.content("object")
	if type(object_id) != "string" or not object_id:
		e.write({"status": "400"})
		return
	if not mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id):
		e.write({"status": "404"})
		return
	attachment = attachment_push_receive(e, object_id, creator=sender)
	if not attachment:
		return
	now = mochi.time.now()
	row_set("objects", "id=?", [object_id], {"updated": now})
	log_activity(object_id, sender, "attached", "", "", attachment["name"])
	broadcast_event(crm_id, "attachment/add", {
		"crm": crm_id, "object": object_id,
		"attachments": [{"id": attachment["id"], "name": attachment["name"], "size": attachment["size"], "content_type": attachment.get("type", ""), "rank": attachment.get("rank", 0), "created": attachment.get("created", now)}]
	}, exclude=sender)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "attachment/create", "crm": crm_id, "object": object_id})

def action_attachment_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	attachments = attachment_list(object_id, crm_id) or []

	return {"data": {"attachments": attachments}}

def action_attachment_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	if crm["owner"] != 1:
		row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
		if not row:
			a.error.label(404, "errors.object_not_found")
			return
		# Save locally
		attachments = attachment_save(a, object_id) or []
		if not attachments:
			a.error.label(400, "errors.file_is_required")
			return
		# The owner is canonical: the bytes go to it now, synchronously, and
		# the metadata fans out from there. A push that fails unwinds the
		# local save - an upload only this host can see is the broken state
		# this scheme exists to remove (#484).
		if not attachment_push(crm_id, object_id, attachments, a.user.identity.id):
			for att in attachments:
				attachment_delete(att["id"])
			a.error.label(502, "errors.could_not_reach_crm_owner")
			return
		return {"data": {"attachments": attachments}}

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	now = mochi.time.now()

	# Save uploaded files locally
	attachments = attachment_save(a, object_id) or []

	if not attachments:
		a.error.label(400, "errors.file_is_required")
		return

	row_set("objects", "id=?", [object_id], {"updated": now})
	for att in attachments:
		log_activity(object_id, a.user.identity.id, "attached", "", "", att["name"])

	# Broadcast attachment metadata to subscribers
	broadcast_event(crm_id, "attachment/add", {
		"crm": crm_id, "object": object_id,
		"attachments": [{"id": att["id"], "name": att["name"], "size": att["size"], "content_type": att.get("type", ""), "rank": att.get("rank", 0), "created": att.get("created", now)} for att in attachments]
	})

	return {"data": {"attachments": attachments}}

# Copies attachments of objects in this CRM onto an object, as Create does for
# a copy of an object. The ids arrive comma-separated.
def action_attachment_copy(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	params = {
		"crm": crm_id, "object": a.input("object", ""),
		"attachments": [id for id in a.input("attachments", "").split(",") if id],
	}
	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "attachment/copy", params)

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	result = do_attachment_copy(crm_id, crm, params, a.user.identity.id)
	if result.get("error"):
		a.error.label(result["code"], result["error"])
		return
	return {"data": result}

def action_attachment_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "attachment/delete", {
			"crm": crm_id, "object": a.input("object"),
			"attachment": a.input("attachment"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	object_id = a.input("object")
	attachment_id = a.input("attachment")
	if not attachment_id:
		a.error.label(400, "errors.attachment_id_required")
		return

	if object_id:
		if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
			a.error.label(404, "errors.object_not_found")
			return

	if not attachment_exists(attachment_id):
		a.error.label(404, "errors.attachment_not_found")
		return

	if not attachment_in_crm(attachment_id, crm_id):
		a.error.label(404, "errors.attachment_not_found")
		return

	attachment_delete(attachment_id)

	# Broadcast delete to subscribers
	broadcast_event(crm_id, "attachment/remove", {
		"crm": crm_id, "attachment": attachment_id
	})

	return {"data": {"success": True}}

# ============================================================================
# Activity Actions
# ============================================================================

def action_activity_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id, class from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	limit = safe_int(a.input("limit"), 100)
	offset = safe_int(a.input("offset"))
	if limit < 1 or limit > 500:
		limit = 100

	# Newest first; the id settles entries logged in the same second, so a
	# page boundary neither repeats nor skips one.
	rows = mochi.db.rows(
		"select id, user, action, field, oldvalue, newvalue, created from activity where object=? order by created desc, id desc limit ? offset ?",
		object_id, limit, offset
	) or []

	# Field and option ids are unique only within a class, so what an entry
	# names is looked up in the object's own class. Names are resolved once
	# per distinct person, as each is a lookup in core.
	lookup = {
		"crm": crm_id,
		"fields": {f["id"]: f for f in mochi.db.rows("select id, name, fieldtype from fields where crm=? and class=?", crm_id, row["class"]) or []},
		"options": {},
		"classes": {c["id"]: c["name"] for c in mochi.db.rows("select id, name from classes where crm=?", crm_id) or []},
		"titles": {},
		"names": {},
	}
	for o in mochi.db.rows("select field, id, name from options where crm=? and class=?", crm_id, row["class"]) or []:
		lookup["options"].setdefault(o["field"], {})[o["id"]] = o["name"]

	activities = []
	for row in rows:
		user = row["user"]
		if user not in lookup["names"]:
			lookup["names"][user] = person_name(user)
		activities.append({
			"id": row["id"],
			"user": user,
			"name": lookup["names"][user],
			"action": row["action"],
			"field": row["field"],
			"oldvalue": row["oldvalue"],
			"newvalue": row["newvalue"],
			"created": row["created"],
			"display": activity_display(row, lookup),
		})

	return {"data": {"activities": activities}}

# activity_display(entry, lookup) -> dict: what an activity entry names, as
# readable text: "field" the name of the field of the object's class it
# changed and "type" that field's type, "old" and "new" an option's name, a
# person's name, an object's title (a move's parents, a link's target, an
# object field) or a class's name (a change of class). A side is left out
# where the client formats the stored value by the field's type, or where it
# names nothing that still exists or has a title.
def activity_display(entry, lookup):
	display = {}
	action = entry["action"]
	field = entry["field"]
	sides = (("old", entry["oldvalue"]), ("new", entry["newvalue"]))
	fields = lookup["fields"]
	if action in ("moved", "linked"):
		for side, value in sides:
			title = activity_title(value, lookup)
			if title:
				display[side] = title
	elif action == "updated" and field == "class" and "class" not in fields:
		for side, value in sides:
			if value in lookup["classes"]:
				display[side] = lookup["classes"][value]
	elif field in fields:
		definition = fields[field]
		display["field"] = definition["name"]
		display["type"] = definition["fieldtype"]
		for side, value in sides:
			if not value:
				continue
			name = ""
			if definition["fieldtype"] == "enumerated":
				name = lookup["options"].get(field, {}).get(value, "")
			elif definition["fieldtype"] == "user":
				if value not in lookup["names"]:
					lookup["names"][value] = person_name(value)
				name = lookup["names"][value]
			elif definition["fieldtype"] == "object":
				name = activity_title(value, lookup)
			if name:
				display[side] = name
	return display

# activity_title(id, lookup) -> string: an object's title; "" for an object
# with none or one this crm does not hold.
def activity_title(id, lookup):
	if not id:
		return ""
	titles = lookup["titles"]
	if id not in titles:
		row = mochi.db.row("select c.title as field from objects o left join classes c on c.crm=o.crm and c.id=o.class where o.id=? and o.crm=?", id, lookup["crm"])
		title = ""
		if row and row["field"]:
			value = mochi.db.row("select value from \"values\" where object=? and field=?", id, row["field"])
			title = value["value"] if value else ""
		titles[id] = title
	return titles[id]

# ============================================================================
# Watcher Actions
# ============================================================================

def action_watcher_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	watchers = mochi.db.rows("select user, created from watchers where object=?", object_id) or []

	# Check if current user is watching
	watching = mochi.db.exists("select 1 from watchers where object=? and user=?", object_id, a.user.identity.id)

	return {"data": {"watchers": watchers, "watching": watching}}

def action_watcher_add(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	# Add current user as watcher
	now = mochi.time.now()
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": a.user.identity.id, "created": now})

	return {"data": {"success": True, "watching": True}}

def action_watcher_remove(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	# Remove current user as watcher
	row_remove("watchers", "object=? and user=?", [object_id, a.user.identity.id])
	return {"data": {"success": True, "watching": False}}

# ============================================================================
# View Actions
# ============================================================================

def action_view_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	views = mochi.db.rows(
		"select id, name, viewtype, filter, columns, rows, sort, direction, rank, border from views where crm=? order by rank, name",
		crm_id
	) or []

	# Batch-fetch view classes and fields
	all_view_classes = mochi.db.rows("select view, class from view_classes where crm=?", crm_id) or []
	vc_map = {}
	for vc in all_view_classes:
		vc_map.setdefault(vc["view"], []).append(vc["class"])
	all_view_fields = mochi.db.rows("select view, field from view_fields where crm=? order by rank", crm_id) or []
	vf_map = {}
	for vf in all_view_fields:
		vf_map.setdefault(vf["view"], []).append(vf["field"])
	for v in views:
		v["classes"] = vc_map.get(v["id"], [])
		v["fields"] = ",".join(vf_map.get(v["id"], []))

	return {"data": {"views": views}}

# view_payload(crm_id, view_id) -> the view/create and view/update broadcast:
# the view as stored, in the shape the schema and the dump give a view (its
# fields and classes comma-joined, its rank included), with the CRM. Read back
# after the write, so the live event and a resync cannot differ. None when the
# view is gone.
def view_payload(crm_id, view_id):
	row = mochi.db.row("select id, name, viewtype, filter, columns, rows, sort, direction, rank, border from views where crm=? and id=?", crm_id, view_id)
	if not row:
		return None
	view = schema_shape(crm_id, "views", [dict(row)])[0]
	view["crm"] = crm_id
	return view

# view_classes_invalid(crm_id, csv): does a comma-separated class list name a
# class the CRM does not have? The junction row carries a foreign key, so an
# unknown id used to abort the write half way through as a 500.
def view_classes_invalid(crm_id, csv):
	if csv == None or csv == "":
		return False
	if type(csv) != "string":
		return True
	for class_id in csv.split(","):
		if class_id.strip() and not mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id.strip()):
			return True
	return False

# view_fields_default(crm_id, csv) -> str: the card fields a new view shows
# when the request names none - the title field of each class the view covers
# (every class when csv is empty). The template classes have no priority,
# owner or due, so a fixed list of those showed nothing on the cards.
def view_fields_default(crm_id, csv):
	wanted = [c.strip() for c in (csv or "").split(",") if c.strip()]
	fields = []
	for row in mochi.db.rows("select id, title from classes where crm=? order by rank", crm_id) or []:
		if wanted and row["id"] not in wanted:
			continue
		if row["title"] and row["title"] not in fields:
			fields.append(row["title"])
	return ",".join(fields) or "title"

def action_view_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "view/create", {
			"crm": crm_id, "name": a.input("name"),
			"viewtype": a.input("viewtype") or "board",
			"filter": a.input("filter") or "",
			"columns": a.input("columns") or "",
			"rows": a.input("rows") or "",
			"fields": a.input("fields") or "",
			"sort": a.input("sort") or "",
			"direction": a.input("direction") or "asc",
			"classes": a.input("classes") or "",
			"border": a.input("border") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	name = a.input("name")
	if not name or not name.strip():
		a.error.label(400, "errors.name_is_required")
		return
	if len(name) > 100:
		a.error.label(400, "errors.name_too_long")
		return

	# Cap the view-config strings, matching do_view_create's P2P path so the
	# owner-side entry point can't store unbounded values either.
	for vf in ["filter", "columns", "rows", "fields", "sort", "border"]:
		if check_length(a.input(vf), 10000):
			a.error.label(400, "errors.value_too_long")
			return

	viewtype = a.input("viewtype") or "board"
	if viewtype not in VIEW_TYPES:
		a.error.label(400, "errors.invalid_view_type")
		return

	# Generate view ID from name
	view_id = structural_id(name)
	if not view_id:
		a.error.label(400, "errors.invalid_name")
		return

	# Check if ID already exists
	existing = mochi.db.exists("select 1 from views where crm=? and id=?", crm_id, view_id)
	if existing:
		a.error.label(400, "errors.view_name_taken")
		return

	filter_str = a.input("filter") or ""
	columns = a.input("columns") or ""
	if viewtype == "board" and not columns:
		a.error.label(400, "errors.columns_field_is_required_for_board_views")
		return
	rows = a.input("rows") or ""
	view_classes = a.input("classes") or ""
	if view_classes_invalid(crm_id, view_classes):
		a.error.label(400, "errors.class_not_found")
		return
	fields = a.input("fields") or view_fields_default(crm_id, view_classes)
	sort = a.input("sort") or ""
	direction = a.input("direction") or "asc"
	border = a.input("border") or ""

	# Assign next rank
	next_rank = mochi.db.row("select coalesce(max(rank), -1) + 1 as r from views where crm=?", crm_id)
	rank = next_rank["r"] if next_rank else 0

	row_merge("views", ["crm", "id"], {"crm": crm_id, "id": view_id, "name": name.strip(), "viewtype": viewtype, "filter": filter_str, "columns": columns, "rows": rows, "sort": sort, "direction": direction, "rank": rank, "border": border})

	# Add fields to junction table
	for i, field in enumerate(fields.split(",")):
		if field.strip():
			row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field.strip(), "rank": i})

	# Add classes to junction table
	if view_classes:
		for cls_id in [c.strip() for c in view_classes.split(",") if c.strip()]:
			row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": cls_id})

	payload = view_payload(crm_id, view_id)
	if payload:
		broadcast_event(crm_id, "view/create", payload)

	return {"data": {
		"id": view_id,
		"name": name.strip(),
		"viewtype": viewtype
	}}

def action_view_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		params = {"crm": crm_id, "view": a.input("view")}
		for k in ["name", "viewtype", "filter", "columns", "rows", "fields", "sort", "direction", "classes", "border"]:
			if a.input(k) != None:
				params[k] = a.input(k)
		return forward_to_owner(a, crm_id, "view/update", params)

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	view_id = a.input("view")
	if not view_id:
		a.error.label(400, "errors.view_id_required")
		return

	view = mochi.db.row("select * from views where crm=? and id=?", crm_id, view_id)
	if not view:
		a.error.label(404, "errors.view_not_found")
		return

	# Cap the view-config strings, matching do_view_update's P2P path so the
	# owner-side entry point can't store unbounded values either.
	for vf in ["filter", "columns", "rows", "fields", "sort", "border"]:
		if check_length(a.input(vf), 10000):
			a.error.label(400, "errors.value_too_long")
			return
	if view_classes_invalid(crm_id, a.input("classes")):
		a.error.label(400, "errors.class_not_found")
		return

	# Update fields if provided
	name = a.input("name")
	viewtype = a.input("viewtype")
	filter_str = a.input("filter")
	columns = a.input("columns")
	rows = a.input("rows")
	fields = a.input("fields")
	sort = a.input("sort")
	direction = a.input("direction")

	if a.input("name") != None and name.strip() != "":
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"name": name.strip()})
	if a.input("viewtype") != None and viewtype != "":
		if viewtype not in VIEW_TYPES:
			a.error.label(400, "errors.invalid_view_type")
			return
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"viewtype": viewtype})
	if a.input("filter") != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"filter": filter_str})
	if a.input("columns") != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"columns": columns})
	if a.input("rows") != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"rows": rows})
	if a.input("fields") != None:
		# Delete existing fields and insert new ones
		row_remove("view_fields", "crm=? and view=?", [crm_id, view_id])
		for i, field in enumerate(fields.split(",")):
			if field.strip():
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field.strip(), "rank": i})
	if a.input("sort") != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"sort": sort})
	if a.input("direction") != None and direction != "":
		if direction not in VIEW_DIRECTIONS:
			a.error.label(400, "errors.invalid_direction")
			return
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"direction": direction})
	border = a.input("border")
	if a.input("border") != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"border": border})
	# Update view classes if provided (comma-separated list of class IDs, empty string = all classes)
	view_classes_input = a.input("classes")
	if a.input("classes") != None:
		# Delete existing view classes
		row_remove("view_classes", "crm=? and view=?", [crm_id, view_id])
		# Insert new view classes
		if view_classes_input:
			cls_ids = [c.strip() for c in view_classes_input.split(",") if c.strip()]
			for cls_id in cls_ids:
				row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": cls_id})

	# Read back updated view for broadcast
	payload = view_payload(crm_id, view_id)
	if payload:
		broadcast_event(crm_id, "view/update", payload)

	return {"data": {"success": True}}

def action_view_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "view/delete", {
			"crm": crm_id, "view": a.input("view"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	view_id = a.input("view")
	if not view_id:
		a.error.label(400, "errors.view_id_required")
		return

	# Don't allow deleting the last view
	count = mochi.db.row("select count(*) as cnt from views where crm=?", crm_id)
	if count and count["cnt"] <= 1:
		a.error.label(400, "errors.cannot_delete_the_last_view")
		return

	row_remove("view_fields", "crm=? and view=?", [crm_id, view_id])
	row_remove("view_classes", "crm=? and view=?", [crm_id, view_id])
	row_remove("views", "crm=? and id=?", [crm_id, view_id])
	broadcast_event(crm_id, "view/delete", {"crm": crm_id, "id": view_id})

	return {"data": {"success": True}}

def action_view_reorder(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "view/reorder", {
			"crm": crm_id, "order": a.input("order") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	# Get order (comma-separated view IDs)
	order_str = a.input("order") or ""
	order = [v.strip() for v in order_str.split(",") if v.strip()]

	# Update rank for each view
	for i, view_id in enumerate(order):
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"rank": i})

	broadcast_event(crm_id, "view/reorder", {"crm": crm_id, "order": order})

	return {"data": {"success": True}}

# ============================================================================
# Type Actions
# ============================================================================

def action_class_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	classes = mochi.db.rows("select id, name, rank, title from classes where crm=? order by rank", crm_id) or []

	return {"data": {"classes": classes}}

def action_class_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "class/create", {
			"crm": crm_id, "name": a.input("name"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	name = a.input("name")
	if not name or not name.strip():
		a.error.label(400, "errors.name_is_required")
		return
	if len(name) > 100:
		a.error.label(400, "errors.name_too_long")
		return

	# Generate class ID from name
	class_id = structural_id(name)
	if not class_id:
		a.error.label(400, "errors.invalid_name")
		return

	# Check if ID already exists
	existing = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id)
	if existing:
		a.error.label(400, "errors.class_name_taken")
		return

	# Get max rank
	max_rank = mochi.db.row("select max(rank) as m from classes where crm=?", crm_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0

	row_merge("classes", ["crm", "id"], {"crm": crm_id, "id": class_id, "name": name.strip(), "rank": rank, "title": "title"})

	# Add default title field
	row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": class_id, "id": "title", "name": mochi.app.label("field.title"), "fieldtype": "text", "flags": "required,sort", "rank": 0})

	# Set hierarchy to allow root by default
	row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": class_id, "parent": ""})

	broadcast_event(crm_id, "class/create", {
		"crm": crm_id, "id": class_id, "name": name.strip(), "rank": rank, "title": "title"
	})

	return {"data": {"id": class_id, "name": name.strip(), "rank": rank}}

def action_class_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		params = {"crm": crm_id, "class": a.input("class")}
		n = a.input("name")
		if n:
			params["name"] = n
		# Forwarded only when supplied, but "" is supplied - it is the title
		# picker's "None". Dropping it here made clearing a title from a
		# subscriber a no-op even once the owner side could honour it.
		t = a.input("title")
		if t != None:
			params["title"] = t
		return forward_to_owner(a, crm_id, "class/update", params)

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error.label(400, "errors.type_id_required")
		return

	class_row = mochi.db.row("select * from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		a.error.label(404, "errors.class_not_found")
		return

	name = a.input("name")
	if check_length(name, 100):
		a.error.label(400, "errors.name_too_long")
		return
	if name != None and not name.strip():
		a.error.label(400, "errors.name_is_required")
		return
	# a.input returns None for a field the client omitted and "" for the "None"
	# option in the title picker, so the two have to be told apart: testing
	# truthiness alone made clearing the title a silent no-op.
	title_input = a.input("title")
	if title_input != None and title_input != "":
		if not mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, title_input):
			a.error.label(400, "errors.field_not_found")
			return
	if name:
		row_set("classes", "crm=? and id=?", [crm_id, class_id], {"name": name.strip()})
	if title_input != None:
		row_set("classes", "crm=? and id=?", [crm_id, class_id], {"title": title_input})
	broadcast_event(crm_id, "class/update", {
		"crm": crm_id, "id": class_id, "name": name or class_row["name"],
		"title": title_input if title_input != None else class_row["title"]
	})

	return {"data": {"success": True}}

def action_class_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "class/delete", {
			"crm": crm_id, "class": a.input("class"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error.label(400, "errors.class_id_required")
		return

	# Check if there are objects of this class
	has_objects = mochi.db.exists("select 1 from objects where crm=? and class=?", crm_id, class_id)
	if has_objects:
		a.error.label(400, "errors.class_in_use")
		return

	# Delete in dependency order. view_classes has a foreign key to
	# classes(crm, id), so its rows MUST go before the class row or the delete
	# fails with "FOREIGN KEY constraint failed". hierarchy rows where this
	# class is a parent have no FK but would be left dangling, so clear them too.
	row_remove("options", "crm=? and class=?", [crm_id, class_id])
	row_remove("fields", "crm=? and class=?", [crm_id, class_id])
	row_remove("view_classes", "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", "crm=? and parent=?", [crm_id, class_id])
	row_remove("classes", "crm=? and id=?", [crm_id, class_id])
	broadcast_event(crm_id, "class/delete", {"crm": crm_id, "id": class_id})

	return {"data": {"success": True}}

# ============================================================================
# Hierarchy Actions
# ============================================================================

def action_hierarchy_get(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	class_id = a.input("class")
	if not class_id:
		a.error.label(400, "errors.type_id_required")
		return

	parents = mochi.db.rows("select parent from hierarchy where crm=? and class=?", crm_id, class_id) or []
	parent_list = [p["parent"] for p in parents]

	return {"data": {"parents": parent_list}}

# hierarchy_parents(crm_id, class_id) -> the parents the class's rules name as
# stored ("" for the top level), read back after a write so subscribers are
# sent what the owner holds: a submitted parent naming no class is skipped.
def hierarchy_parents(crm_id, class_id):
	return [h["parent"] for h in mochi.db.rows("select parent from hierarchy where crm=? and class=?", crm_id, class_id) or []]

def action_hierarchy_set(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "hierarchy/set", {
			"crm": crm_id, "class": a.input("class"),
			"parents": a.input("parents"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error.label(400, "errors.type_id_required")
		return

	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		a.error.label(404, "errors.type_not_found")
		return

	# Get parents list (comma-separated)
	# Empty string in list means "can be root" (no parent required)
	# "_none_" means no parents allowed (empty list)
	parents_str = a.input("parents")
	if parents_str == None or parents_str == "_none_":
		parents = []
	elif parents_str == "":
		# Empty string input means "can be root"
		parents = [""]
	else:
		parents = [p.strip() for p in parents_str.split(",")]

	# Delete existing hierarchy
	row_remove("hierarchy", "crm=? and class=?", [crm_id, class_id])
	# Insert new hierarchy entries
	for parent in parents:
		# Verify parent class exists (unless it's empty string for root)
		if parent and parent != "":
			parent_exists = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, parent)
			if not parent_exists:
				continue  # Skip invalid parents
		row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": class_id, "parent": parent})

	broadcast_event(crm_id, "hierarchy/set", {
		"crm": crm_id, "class": class_id, "parents": hierarchy_parents(crm_id, class_id)
	})

	return {"data": {"success": True}}

# ============================================================================
# Field Actions
# ============================================================================

def action_field_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	class_id = a.input("class")
	if not class_id:
		a.error.label(400, "errors.class_id_required")
		return

	fields = mochi.db.rows(
		"select id, name, fieldtype, flags, multi, rank, min, max, pattern, minlength, maxlength, prefix, suffix, format, card, position, rows from fields where crm=? and class=? order by rank",
		crm_id, class_id
	) or []

	return {"data": {"fields": fields}}

def action_field_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "field/create", {
			"crm": crm_id, "class": a.input("class"),
			"name": a.input("name"), "fieldtype": a.input("fieldtype") or "text",
			"flags": a.input("flags") or "", "multi": a.input("multi") or "0",
			"card": a.input("card") or "1", "rows": a.input("rows") or "1",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error.label(400, "errors.type_id_required")
		return

	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		a.error.label(404, "errors.type_not_found")
		return

	name = a.input("name")
	if not name or not name.strip():
		a.error.label(400, "errors.name_is_required")
		return
	if len(name) > 100:
		a.error.label(400, "errors.name_too_long")
		return

	fieldtype = a.input("fieldtype") or "text"
	if fieldtype not in FIELD_TYPES:
		a.error.label(400, "errors.invalid_field_type")
		return

	# Generate field ID from name
	field_id = structural_id(name)
	if not field_id:
		a.error.label(400, "errors.invalid_name")
		return

	# Check if ID already exists
	existing = mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if existing:
		a.error.label(400, "errors.a_field_with_this_name_already_exists")
		return

	# Get max rank
	max_rank = mochi.db.row("select max(rank) as m from fields where crm=? and class=?", crm_id, class_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0

	flags = a.input("flags") or ""
	multi = 1 if a.input("multi") == "1" or a.input("multi") == "true" else 0
	card = 1 if a.input("card") != "0" and a.input("card") != "false" else 0
	rows = safe_int(a.input("rows"), 1)

	row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": class_id, "id": field_id, "name": name.strip(), "fieldtype": fieldtype, "flags": flags, "multi": multi, "rank": rank, "card": card, "rows": rows})

	broadcast_event(crm_id, "field/create", {
		"crm": crm_id, "class": class_id, "id": field_id,
		"name": name.strip(), "fieldtype": fieldtype, "flags": flags,
		"multi": multi, "rank": rank, "card": card, "rows": rows
	})

	return {"data": {"id": field_id, "name": name.strip(), "fieldtype": fieldtype, "rank": rank}}

def action_field_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		params = {"crm": crm_id, "class": a.input("class"), "field": a.input("field")}
		for k in FIELD_ATTRIBUTES:
			if a.input(k) != None:
				params[k] = a.input(k)
		return forward_to_owner(a, crm_id, "field/update", params)

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	if not class_id or not field_id:
		a.error.label(400, "errors.type_and_field_id_required")
		return

	field_row = mochi.db.row("select * from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field_row:
		a.error.label(404, "errors.field_not_found")
		return

	# Update fields if provided
	update_data = {"crm": crm_id, "class": class_id, "id": field_id}

	# The P2P twin caps every attribute; this path stored them unbounded.
	if check_length(a.input("name"), 100):
		a.error.label(400, "errors.name_too_long")
		return
	if check_length(a.input("flags"), 200) or check_length(a.input("id"), 100):
		a.error.label(400, "errors.value_too_long")
		return
	for k in ["min", "max", "pattern", "prefix", "suffix", "format", "position"]:
		if check_length(a.input(k), 1000):
			a.error.label(400, "errors.value_too_long")
			return

	if a.input("name") != None:
		name = a.input("name").strip()
		if not name:
			a.error.label(400, "errors.name_is_required")
			return
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"name": name})
		update_data["name"] = name
	if a.input("flags") != None:
		flags = a.input("flags")
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"flags": flags})
		update_data["flags"] = flags
	if a.input("multi") != None:
		multi_val = 1 if a.input("multi") in ("1", "true") else 0
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"multi": multi_val})
		update_data["multi"] = multi_val
	if a.input("card") != None:
		card_val = 1 if a.input("card") in ("1", "true") else 0
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"card": card_val})
		update_data["card"] = card_val
	if a.input("min") != None:
		min_val = a.input("min")
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"min": min_val})
		update_data["min"] = min_val
	if a.input("max") != None:
		max_val = a.input("max")
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"max": max_val})
		update_data["max"] = max_val
	if a.input("pattern") != None:
		pattern = a.input("pattern")
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"pattern": pattern})
		update_data["pattern"] = pattern
	if a.input("minlength") != None:
		minlength = safe_int(a.input("minlength"))
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"minlength": minlength})
		update_data["minlength"] = minlength
	if a.input("maxlength") != None:
		maxlength = safe_int(a.input("maxlength"))
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"maxlength": maxlength})
		update_data["maxlength"] = maxlength
	if a.input("prefix") != None:
		prefix = a.input("prefix")
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"prefix": prefix})
		update_data["prefix"] = prefix
	if a.input("suffix") != None:
		suffix = a.input("suffix")
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"suffix": suffix})
		update_data["suffix"] = suffix
	if a.input("format") != None:
		format_str = a.input("format")
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"format": format_str})
		update_data["format"] = format_str
	if a.input("position") != None:
		position = a.input("position")
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"position": position})
		update_data["position"] = position
	if a.input("rows") != None:
		rows_val = safe_int(a.input("rows"), 1)
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rows": rows_val})
		update_data["rows"] = rows_val

	# Rename field ID if requested
	if a.input("id") != None:
		new_id = a.input("id").strip().lower()
		if not new_id:
			a.error.label(400, "errors.field_id_cannot_be_empty")
			return
		if new_id != field_id:
			# Validate: lowercase alphanumeric + underscores only
			for ch in new_id.elems():
				if ch != "_" and not ch.isalnum():
					a.error.label(400, "errors.invalid_field_id")
					return
			# Check for duplicates
			if mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, new_id):
				a.error.label(400, "errors.a_field_with_this_id_already_exists")
				return
			rename_field_id(crm_id, class_id, field_id, new_id)
			update_data["previous"] = field_id
			update_data["id"] = new_id

	broadcast_event(crm_id, "field/update", update_data)

	return {"data": {"success": True}}

def action_field_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "field/delete", {
			"crm": crm_id, "class": a.input("class"),
			"field": a.input("field"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	if not class_id or not field_id:
		a.error.label(400, "errors.type_and_field_id_required")
		return

	field_remove(crm_id, class_id, field_id)
	broadcast_event(crm_id, "field/delete", {"crm": crm_id, "class": class_id, "id": field_id})

	return {"data": {"success": True}}

def action_field_reorder(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "field/reorder", {
			"crm": crm_id, "class": a.input("class"),
			"order": a.input("order") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error.label(400, "errors.type_id_required")
		return

	# Get order (comma-separated field IDs)
	order_str = a.input("order") or ""
	order = [f.strip() for f in order_str.split(",") if f.strip()]

	# Update rank for each field
	for i, field_id in enumerate(order):
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rank": i})

	broadcast_event(crm_id, "field/reorder", {"crm": crm_id, "class": class_id, "order": order})

	return {"data": {"success": True}}

# ============================================================================
# Option Actions
# ============================================================================

def action_option_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	class_id = a.input("class")
	field_id = a.input("field")
	if not class_id or not field_id:
		a.error.label(400, "errors.type_and_field_id_required")
		return

	options = mochi.db.rows(
		"select id, name, colour, icon, rank from options where crm=? and class=? and field=? order by rank",
		crm_id, class_id, field_id
	) or []

	return {"data": {"options": options}}

def action_option_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "option/create", {
			"crm": crm_id, "class": a.input("class"),
			"field": a.input("field"), "name": a.input("name"),
			"colour": a.input("colour") or "#94a3b8",
			"icon": a.input("icon") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	if not class_id or not field_id:
		a.error.label(400, "errors.type_and_field_id_required")
		return

	# Verify field exists and is enumerated
	field_row = mochi.db.row("select fieldtype from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field_row:
		a.error.label(404, "errors.field_not_found")
		return
	if field_row["fieldtype"] != "enumerated":
		a.error.label(400, "errors.field_not_enumerated")
		return

	name = a.input("name")
	if not name or not name.strip():
		a.error.label(400, "errors.name_is_required")
		return
	if len(name) > 100:
		a.error.label(400, "errors.name_too_long")
		return

	# Generate option ID from name
	option_id = structural_id(name)
	if not option_id:
		a.error.label(400, "errors.invalid_name")
		return

	# Check if ID already exists
	existing = mochi.db.exists("select 1 from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
	if existing:
		a.error.label(400, "errors.an_option_with_this_name_already_exists")
		return

	# Get max rank
	max_rank = mochi.db.row("select max(rank) as m from options where crm=? and class=? and field=?", crm_id, class_id, field_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0

	colour = a.input("colour") or "#94a3b8"
	if len(colour) > 20:
		a.error.label(400, "errors.colour_too_long")
		return
	icon = a.input("icon") or ""
	if len(icon) > 100:
		a.error.label(400, "errors.icon_too_long")
		return

	row_merge("options", ["crm", "class", "field", "id"], {"crm": crm_id, "class": class_id, "field": field_id, "id": option_id, "name": name.strip(), "colour": colour, "icon": icon, "rank": rank})

	broadcast_event(crm_id, "option/create", {
		"crm": crm_id, "class": class_id, "field": field_id,
		"id": option_id, "name": name.strip(), "colour": colour, "icon": icon, "rank": rank
	})

	return {"data": {"id": option_id, "name": name.strip(), "colour": colour, "rank": rank}}

def action_option_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		params = {"crm": crm_id, "class": a.input("class"),
				  "field": a.input("field"), "option": a.input("option")}
		for k in ["name", "colour", "icon"]:
			if a.input(k) != None:
				params[k] = a.input(k)
		return forward_to_owner(a, crm_id, "option/update", params)

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	option_id = a.input("option")
	if not class_id or not field_id or not option_id:
		a.error.label(400, "errors.option_id_required")
		return

	option_row = mochi.db.row("select * from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
	if not option_row:
		a.error.label(404, "errors.option_not_found")
		return

	name = a.input("name")
	colour = a.input("colour")
	icon = a.input("icon")

	if a.input("name") != None:
		if not name or not name.strip():
			a.error.label(400, "errors.name_is_required")
			return
		if len(name) > 100:
			a.error.label(400, "errors.name_too_long")
			return
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"name": name.strip()})
	if a.input("colour") != None:
		if len(colour) > 20:
			a.error.label(400, "errors.colour_too_long")
			return
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"colour": colour})
	if a.input("icon") != None:
		if len(icon) > 100:
			a.error.label(400, "errors.icon_too_long")
			return
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"icon": icon})
	update_data = {"crm": crm_id, "class": class_id, "field": field_id, "id": option_id}
	if a.input("name") != None:
		update_data["name"] = name.strip()
	if a.input("colour") != None:
		update_data["colour"] = colour
	if a.input("icon") != None:
		update_data["icon"] = icon
	broadcast_event(crm_id, "option/update", update_data)

	return {"data": {"success": True}}

def action_option_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "option/delete", {
			"crm": crm_id, "class": a.input("class"),
			"field": a.input("field"), "option": a.input("option"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	option_id = a.input("option")
	if not class_id or not field_id or not option_id:
		a.error.label(400, "errors.option_id_required")
		return

	row_remove("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id])
	broadcast_event(crm_id, "option/delete", {"crm": crm_id, "class": class_id, "field": field_id, "id": option_id})

	return {"data": {"success": True}}

def action_option_reorder(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error.label(400, "errors.crm_id_required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "option/reorder", {
			"crm": crm_id, "class": a.input("class"),
			"field": a.input("field"), "order": a.input("order") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error.label(403, "errors.access_denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	if not class_id or not field_id:
		a.error.label(400, "errors.type_and_field_id_required")
		return

	# Get order (comma-separated option IDs)
	order_str = a.input("order") or ""
	order = [o.strip() for o in order_str.split(",") if o.strip()]

	# Update sort order for each option
	for i, option_id in enumerate(order):
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"rank": i})

	broadcast_event(crm_id, "option/reorder", {"crm": crm_id, "class": class_id, "field": field_id, "order": order})

	return {"data": {"success": True}}

# Search for crms in the directory
# crm_url_parse(url) -> (server, crm_id): the server and CRM segment of a URL
# of the form [https://]host/crm/<id>[/...] or host/crm/?crm=<id>. server
# carries the protocol (https:// when the URL names none); both are "" when
# the URL has no /crm/ segment or no host.
def crm_url_parse(url):
	protocol = "https://"
	rest = url
	if rest.startswith("https://"):
		rest = rest[8:]
	elif rest.startswith("http://"):
		protocol = "http://"
		rest = rest[7:]
	if "/crm/" not in rest:
		return "", ""
	host, path = rest.split("/crm/", 1)
	if path.startswith("?crm="):
		crm_id = path[5:]
	else:
		crm_id = path.split("/")[0]
	for stop in ["&", "?", "#"]:
		crm_id = crm_id.split(stop)[0]
	if not host:
		return "", ""
	return protocol + host, crm_id

# results_add(results, entry): append a directory entry unless one with its id
# is already listed. None is ignored, so a failed probe needs no branch.
def results_add(results, entry):
	if not entry:
		return
	for r in results:
		if r.get("id") == entry.get("id"):
			return
	results.append(entry)

# crm_remote_probe(server, crm_id) -> entry or None: ask the server's peer for
# the CRM's information. None when the peer is unreachable or answers with an
# error - an ordinary runtime condition, not a handler failure.
def crm_remote_probe(server, crm_id):
	peer = mochi.remote.peer(server)
	if not peer:
		return None
	response = mochi.remote.request(crm_id, "crm", "information", {"crm": crm_id}, peer)
	if not response or response.get("error"):
		return None
	return {
		"id": response.get("id", crm_id),
		"name": response.get("name", ""),
		"fingerprint": response.get("fingerprint", ""),
		"class": "crm",
		"location": server,
	}

def action_search(a):

	search = a.input("search")
	if not search:
		a.error.label(400, "errors.no_search_entered")
		return
	if len(search) > 500:
		a.error.label(400, "errors.search_query_too_long")
		return

	results = []

	# Check if search term is an entity ID (49-51 word characters)
	if mochi.text.valid(search, "entity"):
		entry = mochi.directory.get(search)
		if entry and entry.get("class") == "crm":
			results.append(entry)

	# Check if search term is a fingerprint (9 alphanumeric, with or without hyphens)
	fingerprint = search.replace("-", "")
	if mochi.text.valid(fingerprint, "fingerprint"):
		for entry in mochi.directory.search("crm", "", False, fingerprint=fingerprint):
			results_add(results, entry)

	# A URL naming a CRM: the directory when it is listed there, else the
	# server the URL names, probed over P2P.
	if search.startswith("http://") or search.startswith("https://"):
		server, crm_id = crm_url_parse(search)
		if server and mochi.text.valid(crm_id, "entity"):
			entry = mochi.directory.get(crm_id)
			if entry and entry.get("class") == "crm":
				results_add(results, entry)
			elif not results:
				results_add(results, crm_remote_probe(server, crm_id))
		elif server and mochi.text.valid(crm_id, "fingerprint"):
			for entry in mochi.directory.search("crm", "", False, fingerprint=crm_id.replace("-", "")):
				results_add(results, entry)
			if not results:
				results_add(results, crm_remote_probe(server, crm_id))

	# Also search by name
	for entry in mochi.directory.search("crm", search, False):
		results_add(results, entry)

	return {"data": results}

# ============================================================================
# User/Group Proxy Actions (proxy to people app)
# ============================================================================

def action_users_search(a):
	query = a.input("search", "")
	results = mochi.service.call("people", "users/search", query)
	return {"data": {"results": results}}

def action_groups(a):
	groups = mochi.service.call("people", "groups/list")
	return {"data": {"groups": groups}}

# ============================================================================
# Notification Actions
# ============================================================================

# ============================================================================
# Remote CRMs (Subscribe)
# ============================================================================

# Public endpoint: resolve a crm fingerprint to basic info
# Used by remote servers to resolve fingerprints during search
# Probe a remote crm by URL without subscribing
def action_probe(a):

	url = a.input("url")
	if not url:
		a.error.label(400, "errors.no_url_provided")
		return
	if len(url) > 500:
		a.error.label(400, "errors.invalid_url")
		return

	# mochi://<peer>/<entity> - a share link pins the owner's peer directly,
	# so a private CRM (never directory-listed) resolves without a hostname.
	if url.startswith("mochi://"):
		rest = url[len("mochi://"):]
		if "/" not in rest:
			a.error.label(400, "errors.invalid_data")
			return
		link_peer, path = rest.split("/", 1)
		link_crm = path.split("/")[0]
		# A malformed peer id reaches core's builtin, which aborts the handler
		# as a 500 rather than answering 400.
		if not mochi.text.valid(link_peer, "peer") or not mochi.text.valid(link_crm, "entity"):
			a.error.label(400, "errors.invalid_data")
			return
		response = mochi.remote.request(link_crm, "crm", "information", {"crm": link_crm}, link_peer)
		if not response or response.get("error"):
			remote_error(a, response, 404)
			return
		return {"data": {
			"id": link_crm,
			"name": response.get("name", ""),
			"description": response.get("description", ""),
			"fingerprint": response.get("fingerprint", ""),
			"class": "crm",
			"peer": link_peer,  # subscribe pins the same peer for its initial sync
			"remote": True
		}}

	# Accepts https://host/crm/ENTITY_ID, http://host/crm/ENTITY_ID or host/crm/ENTITY_ID.
	if "/crm/" not in url:
		a.error.label(400, "errors.invalid_url_format_expected_https_server_crm_crm_id")
		return
	server, crm_id = crm_url_parse(url)
	if not server:
		a.error.label(400, "errors.invalid_url")
		return
	if not crm_id or (not mochi.text.valid(crm_id, "entity") and not mochi.text.valid(crm_id, "fingerprint")):
		a.error.label(400, "errors.could_not_extract_valid_crm_id_from_url")
		return

	peer = mochi.remote.peer(server)
	if not peer:
		a.error.label(502, "errors.unable_to_connect_to_server")
		return
	response = mochi.remote.request(crm_id, "crm", "information", {"crm": crm_id}, peer)
	if not response or response.get("error"):
		remote_error(a, response, 404)
		return

	return {"data": {
		"id": response.get("id", crm_id),
		"name": response.get("name", ""),
		"description": response.get("description", ""),
		"fingerprint": response.get("fingerprint", ""),
		"class": "crm",
		"server": server,
		"remote": True
	}}

# Get recommended crms from the recommendations service
def action_recommendations(a):

	# Get user's existing crm IDs
	existing_ids = set()
	rows = mochi.db.rows("select id from crms")
	for row in rows or []:
		existing_ids.add(row["id"])

	# Recommendations from the service, cached for an hour
	items = recommendation_list("crm", user_language(a))
	if items == None:
		return {"data": {"crms": []}}

	recommendations = []

	# Get the server location from the recommendations entity so subscribers can reach the CRMs
	rec_dir = mochi.directory.get(recommendation_entity)
	rec_server = ""
	if rec_dir:
		rec_server = rec_dir.get("location", "")

	for item in items:
		entity_id = item.get("entity", "")
		if entity_id and entity_id not in existing_ids:
			recommendations.append({
				"id": entity_id,
				"name": item.get("name", ""),
				"blurb": item.get("blurb", ""),
				"fingerprint": mochi.entity.fingerprint(entity_id),
				"server": rec_server,
			})

	return {"data": {"crms": recommendations}}

# List the built-in crm templates (from app assets) for the create-crm and
# design-import pickers.
def action_templates(a):
	if not a.user:
		a.error.label(401, "errors.not_logged_in")
		return
	templates = get_templates(user_language(a))
	return {"data": {"templates": templates.values()}}

# Subscribe to a remote crm
# Produce a mochi://<server-peer>/<crm> share link for a CRM the caller owns.
# The link conveys location only - the subscriber still needs an explicit view
# grant (event_subscribe checks check_crm_access) (#209).
def action_share(a): # crm_share
	if not a.user:
		a.error.label(401, "errors.not_logged_in")
		return
	crm_id = a.input("crm")
	if not mochi.text.valid(crm_id, "entity"):
		a.error.label(400, "errors.invalid_data")
		return
	if not mochi.db.exists("select id from crms where id=? and owner=1", crm_id):
		a.error.label(403, "errors.access_denied")
		return
	peer = mochi.server.id()
	return {"data": {"link": "mochi://" + peer + "/" + crm_id, "peer": peer, "crm": crm_id}}

def action_subscribe(a):
	user_id = a.user.identity.id
	started = mochi.time.now()

	crm_id = a.input("crm")
	server = a.input("server")
	peer = a.input("peer")  # from a mochi://<peer>/<crm> share link
	pin = peer
	if not mochi.text.valid(crm_id, "entity"):
		a.error.label(400, "errors.invalid_crm_id")
		return
	if peer and not mochi.text.valid(peer, "peer"):
		a.error.label(400, "errors.invalid_data")
		return
	if server and len(server) > 500:
		a.error.label(400, "errors.invalid_data")
		return

	# Check if already subscribed
	existing = mochi.db.row("select id, owner from crms where id=?", crm_id)
	if existing:
		if existing["owner"] == 1:
			a.error.label(400, "errors.you_own_this_crm")
			return
		# Already subscribed, just return success
		return {"data": {"fingerprint": mochi.entity.fingerprint(crm_id)}}

	# Get crm info from remote or directory
	schema = None
	if peer or server:
		if not peer:
			peer = mochi.remote.peer(server)
		if not peer:
			a.error.label(502, "errors.unable_to_connect_to_server")
			return
		response = remote_dict(mochi.remote.request(crm_id, "crm", "information", {"crm": crm_id}, peer))
		if not response or response.get("error"):
			remote_error(a, response, 404)
			return
		crm_name = response.get("name", "")
		crm_desc = response.get("description", "")
		# Fetch schema so it is available before the frontend navigates
		schema = schema_fetch(crm_id, peer, SCHEMA_START)
	else:
		# Use directory lookup when no server specified. Only a CRM's entry
		# will do: any other entity (a person, a feed) would leave a replica
		# that never fills.
		directory = mochi.directory.get(crm_id)
		if directory == None or len(directory) == 0 or directory.get("class") != "crm":
			a.error.label(404, "errors.unable_to_find_crm_in_directory")
			return
		crm_name = directory.get("name", "")
		crm_desc = ""
		server = directory.get("location", "")
		# Fetch full info and schema from the resolved server. It stops where
		# the branch with a server does: a listing grants nothing, so an owner
		# that refuses, or cannot be reached, leaves no replica that never
		# fills.
		if server:
			peer = mochi.remote.peer(server)
			if not peer:
				a.error.label(502, "errors.unable_to_connect_to_server")
				return
			response = remote_dict(mochi.remote.request(crm_id, "crm", "information", {"crm": crm_id}, peer))
			if not response or response.get("error"):
				remote_error(a, response, 404)
				return
			crm_name = response.get("name", crm_name)
			crm_desc = response.get("description", "")
			schema = schema_fetch(crm_id, peer, SCHEMA_START)

	now = mochi.time.now()
	fp = mochi.entity.fingerprint(crm_id) or ""

	# Insert the remote crm. populated=0: the board shows a loading state until
	# the schema pull below reaches its last part, or every chunk of the owner's
	# sync/batch has landed (event_sync_batch), whichever is first.
	row_merge("crms", ["id"], {"id": crm_id, "name": crm_name, "description": crm_desc, "owner": 0, "server": ("p2p/" + pin) if pin else (server or ""), "fingerprint": fp, "created": now, "updated": now, "populated": 0})

	# Send P2P subscribe message to crm owner. A private CRM is not in the
	# directory, so when the subscription came via a share link, pin that
	# peer - here and, as the stored "p2p/<peer>" server, for every later view,
	# access check, resync, re-subscribe and unsubscribe (see registration_send).
	# Without it they found the owner only once the user's learned directory
	# caught up, and a view just after subscribing answered 502. It goes before
	# the schema is applied, so a pull that stops short still leaves a
	# subscription the owner's sync batch fills.
	if peer:
		mochi.message.send.peer(peer, p2p_headers(user_id, crm_id, "subscribe"), {"name": a.user.identity.name})
	else:
		mochi.message.send(p2p_headers(user_id, crm_id, "subscribe"), {"name": a.user.identity.name})
	mochi.broadcast.touch(crm_id)

	# Apply the first part so the crm page has content at once, and leave the
	# rest to a continuation straight away (a budget of 0): the client gives up
	# on this request after 30 seconds, and each further part may take that
	# long. The board shows its loading state until the last part lands. The
	# replica fills from its own pull: the owner sends the whole CRM on a
	# subscribe only to a subscriber it has not sent it to within
	# snapshot_seconds (event_subscribe), so a first part that could not be
	# fetched now is pulled again once request_resync's throttle has passed.
	if schema and not schema.get("error"):
		pull = schema_begin(crm_id, False)
		schema_claim(crm_id, pull)
		insert_schema(crm_id, schema, peer, started, None, 0, 0, pull)
	else:
		resync_defer(crm_id, False, SCHEMA_LATE)

	return {"data": {"fingerprint": fp}}

# Unsubscribe from a remote crm
def action_unsubscribe(a):
	user_id = a.user.identity.id

	crm_id = a.input("crm")
	if not mochi.text.valid(crm_id, "entity") and not mochi.text.valid(crm_id, "fingerprint"):
		a.error.label(400, "errors.invalid_crm_id")
		return

	# Look up by ID or fingerprint
	crm = mochi.db.row("select * from crms where id=?", crm_id)
	if not crm:
		crm = mochi.db.row("select * from crms where fingerprint=?", crm_id)
		if crm:
			crm_id = crm["id"]

	if not crm:
		a.error.label(404, "errors.crm_not_found")
		return

	if crm["owner"] == 1:
		a.error.label(400, "errors.you_own_this_crm")
		return

	# Delete all local data for this remote crm — physical purge, so a later
	# re-subscribe imports cleanly (see purge_crm).
	# purge_crm clears the attachments, object and comment alike.
	purge_crm(crm_id)
	# Send P2P unsubscribe message
	registration_send(crm["server"], p2p_headers(user_id, crm_id, "unsubscribe"), {})

	return {"data": {"success": True}}

# ============================================================================
# P2P Events
# ============================================================================

# Handle crm info request from a remote server
def event_information(e):
	crm_id = e.header("to")

	entity = mochi.entity.info(crm_id)
	if not entity or entity.get("class") != "crm":
		e.stream.write({"error": "errors.crm_not_found"})
		return

	crm = mochi.db.row("select * from crms where id=?", crm_id)
	if not crm:
		e.stream.write({"error": "errors.crm_not_found"})
		return

	requester = e.header("from")
	if crm["owner"] == 1 and not check_crm_access(requester, crm_id, "view"):
		e.stream.write({"error": "errors.access_denied"})
		return

	e.stream.write({
		"id": entity["id"],
		"name": crm["name"],
		"description": crm["description"],
		"fingerprint": entity.get("fingerprint", mochi.entity.fingerprint(crm_id)),
	})

# Return the full crm schema (classes, fields, options, hierarchy, views)
# attachments_many(ids, crm_id, kind) -> {id: [attachment]}: attachment_list_many
# over any number of ids, all things of that kind, chunked to stay under
# SQLite's parameter cap.
def attachments_many(ids, crm_id, kind="object"):
	result = {}
	for start in range(0, len(ids), IN_CHUNK):
		result.update(attachment_list_many(ids[start:start + IN_CHUNK], crm_id, kind))
	return result

# FIELD_COLUMNS: every column of a field row, the one list the dump, a schema
# part, the sync batch and the replica's writers (field_row) carry, so a
# constraint set on the owner reaches every copy however the copy learns the
# design.
FIELD_COLUMNS = ["class", "id", "name", "fieldtype", "flags", "multi", "rank", "min", "max", "pattern", "minlength", "maxlength", "prefix", "suffix", "format", "card", "position", "rows"]
# The columns of FIELD_COLUMNS that hold whole numbers; the rest hold text.
FIELD_NUMBERS = ["multi", "rank", "minlength", "maxlength", "card", "rows"]
# The constraints and display affixes, which a field row from an owner sets
# only when it carries them (field_limits).
FIELD_LIMITS = ["min", "max", "pattern", "minlength", "maxlength", "prefix", "suffix", "format"]

# roster(crm_id) -> [{id, name}]: the members of a CRM this user owns, its
# owner's own identity first, as subscribers are sent them so their copies
# name the people of the CRM (event_member_add).
def roster(crm_id):
	return [{"id": s["id"], "name": s["name"]} for s in mochi.db.rows("select id, name from subscribers where crm=? order by subscribed, rowid", crm_id) or []]

# crm_dump(crm_id) -> dict: the whole CRM in the flat shape event_schema
# streams - classes, fields, options, hierarchy as {class, parents} rows, views
# with comma-joined field and class lists, every object with its values,
# comments (each with attachments), activity and attachments, and the links.
# Values, comments, activity and attachments are fetched for all objects at
# once through rows_in, so the cost is a fixed handful of queries rather than
# five per object. send_crm_data reshapes it into the sync/batch form.
def crm_dump(crm_id):
	classes = mochi.db.rows("select id, name, rank, title from classes where crm=? order by rank", crm_id) or []
	fields = mochi.db.rows("select " + ", ".join(FIELD_COLUMNS) + " from fields where crm=? order by class, rank", crm_id) or []
	options = mochi.db.rows("select class, field, id, name, colour, icon, rank from options where crm=? order by class, field, rank", crm_id) or []
	hierarchy = []
	hierarchy_map = {}
	for h in mochi.db.rows("select class, parent from hierarchy where crm=?", crm_id) or []:
		hierarchy_map.setdefault(h["class"], []).append(h["parent"])
	for cls, parents in hierarchy_map.items():
		hierarchy.append({"class": cls, "parents": parents})
	views = mochi.db.rows("select id, name, viewtype, filter, columns, rows, sort, direction, rank, border from views where crm=? order by rank, name", crm_id) or []
	vf_map = {}
	for vf in mochi.db.rows("select view, field from view_fields where crm=? order by rank", crm_id) or []:
		vf_map.setdefault(vf["view"], []).append(vf["field"])
	vc_map = {}
	for vc in mochi.db.rows("select view, class from view_classes where crm=?", crm_id) or []:
		vc_map.setdefault(vc["view"], []).append(vc["class"])
	for v in views:
		v["fields"] = ",".join(vf_map.get(v["id"], []))
		v["classes"] = ",".join(vc_map.get(v["id"], []))
	objects = mochi.db.rows("select id, class, parent, rank, created, updated, version from objects where crm=?", crm_id) or []
	ids = [obj["id"] for obj in objects]
	values_map = {}
	comments_map = {}
	activity_map = {}
	comment_ids = []
	if ids:
		for v in rows_in("select object, field, value from \"values\" where object in (", ids, ")"):
			values_map.setdefault(v["object"], {})[v["field"]] = v["value"]
		for c in rows_in("select object, id, parent, author, name, content, created, edited from comments where object in (", ids, ") order by created"):
			comments_map.setdefault(c["object"], []).append(c)
			comment_ids.append(c["id"])
		for act in rows_in("select object, id, user, action, field, oldvalue, newvalue, created from activity where object in (", ids, ") order by created"):
			activity_map.setdefault(act["object"], []).append(act)
	attachments = attachments_many(ids, crm_id)
	comment_attachments = attachments_many(comment_ids, crm_id, "comment")
	for obj in objects:
		if obj["id"] in values_map:
			obj["values"] = values_map[obj["id"]]
		if obj["id"] in comments_map:
			for c in comments_map[obj["id"]]:
				c_atts = comment_attachments.get(c["id"])
				if c_atts:
					c["attachments"] = c_atts
			obj["comments"] = comments_map[obj["id"]]
		if obj["id"] in activity_map:
			obj["activity"] = activity_map[obj["id"]]
		obj_atts = attachments.get(obj["id"])
		if obj_atts:
			obj["attachments"] = obj_atts
	links = mochi.db.rows("select l.source, l.target, l.linktype from links l join objects o on l.source = o.id where o.crm=?", crm_id) or []
	return {"classes": classes, "fields": fields, "options": options, "hierarchy": hierarchy, "views": views, "objects": objects, "links": links}

# Core decodes at most 10,000 elements in one array and 100 MB on one stream,
# each read within 30 seconds, so a large CRM's schema cannot travel as one
# reply. A request carrying `part` (a cursor) is answered with one bounded part:
# at most SCHEMA_ROWS rows and about SCHEMA_BYTES bytes, taken in key order from
# the flat lists in SCHEMA_LISTS, with `next` naming the cursor of the part
# after it. The last part carries no `next`. A request without `part` gets the
# whole schema in the nested shape, as owners before parts answered every one.
SCHEMA_ROWS = 1000
SCHEMA_BYTES = 8388608
SCHEMA_START = {"list": "classes", "after": []}
SCHEMA_LISTS = ["classes", "fields", "options", "hierarchy", "views", "objects", "values", "comments", "activity", "attachments", "links", "members"]
# The most parts one pull follows, across its continuations. Core allows an
# app 600 remote calls a minute to one target.
SCHEMA_PARTS = 500
# The most bytes a cursor key holds. A row whose key is longer could not be
# resumed after, so the owner never pages one.
SCHEMA_KEY = 256
# The seconds a pull runs before it leaves the rest to a continuation, well
# under the time limit of the action or event it runs in.
SCHEMA_TIME = 60
# The seconds a pull that skipped late rows waits before it asks for a fresh
# one: past request_resync's 60-second throttle, so the fresh pull is not
# refused.
SCHEMA_LATE = 61
# How many holdings rows one statement writes or strikes out.
SCHEMA_BATCH = 200
# The lists of what a replica holds that a complete pull may prune
# (schema_holdings), each keyed as schema_named keys what a pull named.
SCHEMA_HELD = ["objects", "comments", "values", "attachments", "links", "classes", "fields", "options", "hierarchy", "views", "view_fields", "view_classes", "members"]
# How many times in a row a continuation whose part went unanswered is tried
# again before the pull waits for the next resync.
SCHEMA_RETRIES = 3

# Each list: the columns a part sends, the rows it reads (bound to the CRM
# by `scope` parameters), the key it is ordered and resumed by, and what a row
# costs in bytes beyond a fixed allowance.
SCHEMA_SPECS = {
	"classes": {"columns": "id, name, rank, title", "source": "classes where crm=?", "scope": 1, "keys": ["id"], "size": "length(cast(name as blob)) + length(cast(title as blob))"},
	"fields": {"columns": ", ".join(FIELD_COLUMNS), "source": "fields where crm=?", "scope": 1, "keys": ["class", "id"], "size": "length(cast(name as blob)) + length(cast(flags as blob)) + length(cast(position as blob)) + length(cast(min as blob)) + length(cast(max as blob)) + length(cast(pattern as blob)) + length(cast(prefix as blob)) + length(cast(suffix as blob)) + length(cast(format as blob))"},
	"options": {"columns": "class, field, id, name, colour, icon, rank", "source": "options where crm=?", "scope": 1, "keys": ["class", "field", "id"], "size": "length(cast(name as blob)) + length(cast(icon as blob))"},
	"hierarchy": {"columns": "class, parent", "source": "hierarchy where crm=?", "scope": 1, "keys": ["class", "parent"], "size": "0"},
	"views": {"columns": "id, name, viewtype, filter, columns, rows, sort, direction, rank, border", "source": "views where crm=?", "scope": 1, "keys": ["id"], "size": "length(cast(name as blob)) + length(cast(filter as blob)) + length(cast(columns as blob)) + length(cast(rows as blob)) + length(cast(sort as blob))"},
	"objects": {"columns": "id, class, parent, rank, created, updated, version", "source": "objects where crm=?", "scope": 1, "keys": ["id"], "size": "0"},
	"values": {"columns": "v.object as object, v.field as field, v.value as value, o.version as version", "source": "\"values\" v join objects o on o.id=v.object where o.crm=?", "scope": 1, "keys": ["v.object", "v.field"], "size": "length(cast(v.value as blob))"},
	"comments": {"columns": "c.object as object, c.id as id, c.parent as parent, c.author as author, c.name as name, c.content as content, c.created as created, c.edited as edited", "source": "comments c join objects o on o.id=c.object where o.crm=?", "scope": 1, "keys": ["c.id"], "size": "length(cast(c.content as blob)) + length(cast(c.name as blob))"},
	"activity": {"columns": "a.object as object, a.id as id, a.user as user, a.action as action, a.field as field, a.oldvalue as oldvalue, a.newvalue as newvalue, a.created as created", "source": "activity a join objects o on o.id=a.object where o.crm=?", "scope": 1, "keys": ["a.id"], "size": "length(cast(a.oldvalue as blob)) + length(cast(a.newvalue as blob))"},
	"attachments": {"columns": "*", "source": "attachments where ((kind='object' and object in (select id from objects where crm=?)) or (kind='comment' and object in (select c.id from comments c join objects o on o.id=c.object where o.crm=?)))", "scope": 2, "keys": ["id"], "size": "960"},
	"links": {"columns": "l.source as source, l.target as target, l.linktype as linktype", "source": "links l join objects o on o.id=l.source where o.crm=?", "scope": 1, "keys": ["l.source", "l.target", "l.linktype"], "size": "0"},
	# The roster (roster); each part's crm block names which member owns the CRM.
	"members": {"columns": "id, name", "source": "subscribers where crm=?", "scope": 1, "keys": ["id"], "size": "length(cast(name as blob))"},
}

# schema_cursor(value) -> bool: whether value is a part cursor: the list the
# part starts in, and the key of the last row already sent from it (empty at the
# start of the list).
def schema_cursor(value):
	if type(value) != "dict" or len(value) != 2:
		return False
	if value.get("list") not in SCHEMA_LISTS:
		return False
	after = value.get("after")
	if type(after) not in ["list", "tuple"]:
		return False
	if after and len(after) != len(SCHEMA_SPECS[value["list"]]["keys"]):
		return False
	for key in after:
		if type(key) != "string" or len(key) > SCHEMA_KEY:
			return False
	return True

# schema_compare(keys, values, last) -> (condition, args): rows whose key sorts
# after values, or, with last, at or before them.
def schema_compare(keys, values, last=False):
	clauses = []
	args = []
	for index in range(len(keys)):
		terms = []
		for earlier in range(index):
			terms.append(keys[earlier] + "=?")
			args.append(values[earlier])
		final = index == len(keys) - 1
		terms.append(keys[index] + ("<=?" if last and final else ("<?" if last else ">?")))
		args.append(values[index])
		clauses.append("(" + " and ".join(terms) + ")")
	return "(" + " or ".join(clauses) + ")", args

# schema_window(sizes, budget) -> how many of sizes (rows in key order, each
# with its size in bytes) fit the part, charging them to the budget. The part's
# first row always fits, so a row larger than the byte budget travels alone.
def schema_window(sizes, budget):
	count = 0
	for row in sizes:
		if budget["rows"] <= 0:
			break
		if budget["taken"] > 0 and row["size"] > budget["bytes"]:
			break
		budget["rows"] -= 1
		budget["bytes"] -= row["size"]
		budget["taken"] += 1
		count += 1
	return count

# schema_list(crm_id, name, after, budget) -> (rows, key): one list's share
# of a part, and the key to resume it from, or None when the list is done. The
# resume key is the last row sent, not the last row sized, so a row written
# between the two queries is never stepped over, and the list is done only when
# every row sized was sent. A row whose key a cursor cannot carry is never paged.
def schema_list(crm_id, name, after, budget):
	if budget["rows"] <= 0:
		return [], list(after)
	spec = SCHEMA_SPECS[name]
	scope = [crm_id] * spec["scope"]
	names = [k.split(".")[-1] for k in spec["keys"]]
	beyond, beyond_args = ("1=1", []) if not after else schema_compare(spec["keys"], after)
	fits = " and ".join(["length(cast(" + k + " as blob))<=?" for k in spec["keys"]])
	fits_args = [SCHEMA_KEY] * len(spec["keys"])
	order = ", ".join(spec["keys"])
	selected = ", ".join([k + " as " + n for k, n in zip(spec["keys"], names)])
	sizes = mochi.db.rows("select " + selected + ", 64 + " + spec["size"] + " as size from " + spec["source"] + " and " + beyond + " and " + fits + " order by " + order + " limit ?", *(scope + beyond_args + fits_args + [budget["rows"] + 1])) or []
	count = schema_window(sizes, budget)
	rows = []
	if count:
		upto, upto_args = schema_compare(spec["keys"], [sizes[count - 1][n] for n in names], True)
		rows = list(mochi.db.rows("select " + spec["columns"] + " from " + spec["source"] + " and " + beyond + " and " + upto + " and " + fits + " order by " + order + " limit ?", *(scope + beyond_args + upto_args + fits_args + [count])) or [])
	if count >= len(sizes) and len(rows) >= count:
		last = None
	elif rows:
		last = [str(rows[-1][n]) for n in names]
	elif count:
		last = [str(sizes[count - 1][n]) for n in names]
	else:
		last = list(after)
	return schema_shape(crm_id, name, rows), last

# schema_shape(crm_id, name, rows) -> rows in the shape design_merge and
# schema_merge read: hierarchy as {class, parents}, views with their field and
# class lists, attachments as the library maps them.
def schema_shape(crm_id, name, rows):
	if name == "hierarchy":
		return [{"class": r["class"], "parents": [r["parent"]]} for r in rows]
	if name == "views" and rows:
		ids = [v["id"] for v in rows]
		marks = ",".join(["?" for _ in ids])
		fields = {}
		for vf in mochi.db.rows("select view, field from view_fields where crm=? and view in (" + marks + ") order by rank", crm_id, *ids) or []:
			fields.setdefault(vf["view"], []).append(vf["field"])
		classes = {}
		for vc in mochi.db.rows("select view, class from view_classes where crm=? and view in (" + marks + ")", crm_id, *ids) or []:
			classes.setdefault(vc["view"], []).append(vc["class"])
		for v in rows:
			v["fields"] = ",".join(fields.get(v["id"], []))
			v["classes"] = ",".join(classes.get(v["id"], []))
		return rows
	if name == "attachments":
		prefix = mochi.app.url()
		return [attachment_map(row, prefix, crm_id) for row in rows]
	return rows

# schema_part(crm_id, cursor) -> (lists, next): one bounded part of the
# schema from cursor on, and the cursor of the part after it, or None after the
# last.
def schema_part(crm_id, cursor):
	budget = {"rows": SCHEMA_ROWS, "bytes": SCHEMA_BYTES, "taken": 0}
	lists = {}
	for name in SCHEMA_LISTS:
		lists[name] = []
	after = list(cursor["after"])
	for name in SCHEMA_LISTS[SCHEMA_LISTS.index(cursor["list"]):]:
		rows, last = schema_list(crm_id, name, after, budget)
		lists[name] = rows
		if last != None:
			return lists, {"list": name, "after": last}
		after = []
	return lists, None

def event_schema(e):
	crm_id = e.header("to")
	# A change's events go out before its transaction commits (events_commit),
	# so a pull one of them set going can arrive while it is still open. Taking
	# the write lock, which it holds until then, waits for it, so what is read
	# below holds the change.
	mochi.db.transaction().commit()
	# Include the crm row's own metadata (name/description) so the
	# subscriber's resync reconciles renames - the directory rename via
	# mochi.entity.update doesn't fire crm/update, so without this dump
	# the row-level name drifts forever. Mirrors projects task #86.
	crm = mochi.db.row("select id, name, description from crms where id=? and owner=1", crm_id)
	if not crm:
		e.stream.write({"error": "errors.crm_not_found"})
		return

	requester = e.header("from")
	if not check_crm_access(requester, crm_id, "view"):
		e.stream.write({"error": "errors.access_denied"})
		return

	# CRM row first so subscribers can reconcile metadata (name /
	# description) on resync without waiting for a crm/update broadcast that
	# might never come.
	# owner names which member of the roster owns the CRM, so a copy names
	# the right person as its owner (member_owner).
	metadata = {
		"name": crm.get("name", ""),
		"description": crm.get("description", ""),
		"owner": get_owner_identity(crm_id),
	}

	# One part of the schema. The gate above runs for every part, so a peer
	# that loses view access stops at its next part; the part echoes its
	# cursor, which tells the requester the reply is held to SCHEMA_ROWS.
	part = e.content("part")
	if part != None:
		if not schema_cursor(part):
			e.stream.write({"error": "errors.invalid_data"})
			return
		lists, next = schema_part(crm_id, part)
		reply = {"crm": metadata, "part": part}
		reply.update(lists)
		if next:
			reply["next"] = next
		e.stream.write(reply)
		return

	dump = crm_dump(crm_id)
	e.stream.write({
		"crm": metadata,
		"classes": dump["classes"],
		"fields": dump["fields"],
		"options": dump["options"],
		"hierarchy": dump["hierarchy"],
		"views": dump["views"],
		"objects": dump["objects"],
		"links": dump["links"],
		"members": roster(crm_id),
	})

# schema_fetch(crm_id, peer, part) -> one part of the owner's schema, or None.
# An owner that predates parts ignores `part` and answers the whole schema,
# which carries no `next` and so is complete on its own.
def schema_fetch(crm_id, peer, part):
	return remote_dict(mochi.remote.request(crm_id, "crm", "schema", {"part": part}, peer))

# A part (a reply echoing its cursor) is held to the rows a part may carry,
# across all its lists. A whole schema from an owner that predates parts is not.
def schema_bounded(schema):
	if schema.get("part") == None:
		return True
	rows = 0
	for name in SCHEMA_LISTS:
		value = schema.get(name)
		if value != None and type(value) not in ["list", "tuple"]:
			return False
		rows += len(value or [])
	return rows <= SCHEMA_ROWS

# Apply a schema from the owner: schema is a part already received, or a whole
# schema, and the parts after it are pulled and applied in turn until budget
# seconds have passed since started; parts counts the parts the pull took
# before this one. Editable tables are upserted in place (primary keys stay
# stable so child foreign keys survive); append-only activity and natural-key
# tables with nothing editable (links, view_classes, hierarchy) stay
# insert-or-ignore. Returns whether the last part arrived, and the replica is
# then populated.
#
# held is what the replica held before the pull began (schema_holdings), in the
# call that begins a pull that prunes, or None. Once the last part has landed, a
# held row the pull did not name was deleted owner-side and goes; a row that
# arrived while the pull ran is never pruned, since a part read before it
# existed could not name it. A pull that stops early prunes nothing: it names
# too little. One that runs out of time is continued by schedule_schema, and one
# whose part goes unanswered is tried again a few times; what it may still prune
# goes with it in holdings (schema_keep). pull is the pull's state (schema_pull),
# which its continuations carry. A pull that is no longer the replica's own
# (schema_current) - the replica was dropped, or a newer pull replaced it -
# stops where it finds that out, and applies no part after.
def insert_schema(crm_id, schema, peer="", started=None, held=None, parts=0, budget=SCHEMA_TIME, pull=None):
	if started == None:
		started = mochi.time.now()
	pull = schema_pull(pull)
	survivors = {"design": {"classes": [], "fields": [], "options": [], "hierarchy": [], "views": []},
		"objects": {}, "comments": {}, "values": {}, "attachments": {}, "links": {}, "members": {}}
	for _ in range(SCHEMA_PARTS):
		if parts >= SCHEMA_PARTS:
			break
		parts += 1
		if not schema_bounded(schema):
			break
		if not schema_current(crm_id, pull):
			return False
		if schema_merge(crm_id, schema, survivors):
			pull["late"] = True
		# Checked again once the part is applied, so also before every fetch
		# the loop makes: a purge that ran while the part was applied left the
		# attachments it stored after the purge's own clearing.
		if not schema_current(crm_id, pull):
			schema_stray(survivors)
			return False
		next = schema.get("next")
		if next == None:
			return schema_finish(crm_id, survivors, held, pull)
		if not schema_cursor(next):
			break
		if mochi.time.now() - started >= budget:
			schema_keep(crm_id, survivors, held, pull)
			schema_resume(crm_id, "stopped", next, parts, 0, pull)
			return False
		# The pull is under way for as long as it fetches: request_resync
		# starts no second one beside it.
		row_set("crms", "id=?", [crm_id], {"synced": mochi.time.now()})
		schema = schema_fetch(crm_id, peer, next)
		if not schema or schema.get("error"):
			outcome = schema_outcome(schema)
			if outcome == "unanswered":
				schema_keep(crm_id, survivors, held, pull)
			schema_resume(crm_id, outcome, next, parts, 0, pull)
			return False
	# A part broke a bound, or the pull reached its cap: it waits for the next
	# resync, so its rows go.
	schema_end(crm_id, pull)
	return False

# schema_pull(value) -> a pull's state as its continuations carry it: id names
# its rows in holdings (schema_begin), prune says it reconciles deletions once
# its last part lands, late says a part named a row whose parent the replica did
# not hold yet, and repeat says the pull is the fresh one a late pull asked for.
# A continuation scheduled before pulls carried an id has none, and stops.
def schema_pull(value):
	pull = {"id": "", "prune": False, "late": False, "repeat": False}
	if type(value) == "dict":
		if type(value.get("id")) == "string" and mochi.text.valid(value["id"], "id"):
			pull["id"] = value["id"]
		pull["prune"] = value.get("prune") == True
		pull["late"] = value.get("late") == True
		pull["repeat"] = value.get("repeat") == True
	return pull

# A pull's rows in holdings, beside what it may still prune (schema_keep): the
# row with an empty list and key says the pull is the replica's own, and the one
# with an empty list and the key SCHEMA_PRUNE says it may still prune. A purge
# deletes every row of the CRM, a newer pull the rows of every pull before it
# (schema_claim), and a live event every row but the first kind (schema_cancel).
SCHEMA_PRUNE = "prune"

# schema_begin(crm_id, prune, repeat) -> the state of a new pull of the replica
# (schema_pull), with its rows in holdings. Written only while the replica is
# held, so a pull that begins beside a purge has none and stops at its first
# part.
def schema_begin(crm_id, prune, repeat=False):
	pull = {"id": mochi.uid(), "prune": prune, "late": False, "repeat": repeat}
	mochi.db.execute("insert or ignore into holdings (crm, pull, list, key) select ?, ?, '', '' where exists (select 1 from crms where id=? and owner=0)", crm_id, pull["id"], crm_id)
	if prune:
		mochi.db.execute("insert or ignore into holdings (crm, pull, list, key) select ?, ?, '', ? where exists (select 1 from crms where id=? and owner=0)", crm_id, pull["id"], SCHEMA_PRUNE, crm_id)
	return pull

# schema_claim(crm_id, pull): a pull whose first part has arrived replaces every
# pull of the replica before it, which stops at its next part, and whatever rows
# an abandoned one left.
def schema_claim(crm_id, pull):
	mochi.db.execute("delete from holdings where crm=? and pull!=?", crm_id, pull["id"])

# schema_end(crm_id, pull): a pull that finished, or stopped for good, leaves no
# rows behind.
def schema_end(crm_id, pull):
	mochi.db.execute("delete from holdings where crm=? and pull=?", crm_id, pull["id"])

# schema_current(crm_id, pull) -> whether the pull is still the replica's own.
def schema_current(crm_id, pull):
	return pull["id"] != "" and mochi.db.exists("select 1 from holdings where crm=? and pull=? and list='' and key=''", crm_id, pull["id"])

# schema_cancel(crm_id): a live event writes to the replica, so a pull under way
# prunes nothing. It could otherwise prune a row the event wrote: the owner
# removes a row the pull held, the pull reads that list without it, and the
# owner puts the row back before the pull's last part lands. What the owner
# deleted meanwhile waits for the next resync.
def schema_cancel(crm_id):
	mochi.db.execute("delete from holdings where crm=? and key!=''", crm_id)

# schema_permit(crm_id, pull) -> the condition, and its arguments, under which
# a pull's prune deletes a row or keeps one to prune: the pull may still prune.
# Checked in the statement itself, so a live event that lands while the prune
# runs stops the rest of it.
def schema_permit(crm_id, pull):
	return "exists (select 1 from holdings where crm=? and pull=? and list='' and key=?)", [crm_id, pull, SCHEMA_PRUNE]

# schema_finish(crm_id, survivors, held, pull) -> whether the pull completed
# the replica: the last part has landed. A pull that prunes reconciles deletions
# against what the replica held before it began: held, when it finishes in the
# call that began it, else what its continuations left in holdings. The replica
# is marked populated only while the pull is still its own, in the same
# statement. A pull that skipped late rows asks for one fresh pull once
# request_resync's throttle has passed, unless it is that fresh pull.
def schema_finish(crm_id, survivors, held, pull):
	if pull["prune"]:
		if held == None:
			held = schema_kept(crm_id, pull["id"])
		schema_prune(crm_id, survivors, held, pull["id"])
	current = mochi.db.execute("update crms set populated=1 where id=? and owner=0 and exists (select 1 from holdings where crm=? and pull=? and list='' and key='')", crm_id, crm_id, pull["id"]) > 0
	schema_end(crm_id, pull)
	if current and pull["late"] and not pull["repeat"]:
		mochi.schedule.after("schedule_resync", {"crm": crm_id}, SCHEMA_LATE)
	return current

# schema_keep(crm_id, survivors, held, pull) records, as a pull that prunes
# hands the rest to a continuation, what its last part may still prune. The call
# that began the pull writes the rows the replica held before it (held) that no
# part so far has named, while the pull may still prune; a continuation strikes
# out the rows its own parts named.
def schema_keep(crm_id, survivors, held, pull):
	if not pull["prune"]:
		return
	named = schema_named(survivors)
	if held != None:
		rows = []
		for name in SCHEMA_HELD:
			for key in held[name]:
				if key not in named[name]:
					rows.append([name, json.encode(key)])
		condition, arguments = schema_permit(crm_id, pull["id"])
		for start in range(0, len(rows), SCHEMA_BATCH):
			batch = rows[start:start + SCHEMA_BATCH]
			mochi.db.execute("insert or ignore into holdings (crm, pull, list, key) select ?, ?, column1, column2 from (values " + ", ".join(["(?, ?)"] * len(batch)) + ") where " + condition, crm_id, pull["id"], [value for row in batch for value in row], arguments)
		return
	for name in SCHEMA_HELD:
		keys = [json.encode(key) for key in named[name]]
		for start in range(0, len(keys), SCHEMA_BATCH):
			batch = keys[start:start + SCHEMA_BATCH]
			mochi.db.execute("delete from holdings where crm=? and pull=? and list=? and key in (" + ", ".join(["?"] * len(batch)) + ")", crm_id, pull["id"], name, batch)

# schema_kept(crm_id, pull) -> what a pull's continuations left it to prune,
# shaped as schema_holdings shapes it: nothing, once a live event cancelled the
# prune.
def schema_kept(crm_id, pull):
	held = {}
	for name in SCHEMA_HELD:
		held[name] = {}
	for row in mochi.db.rows("select list, key from holdings where crm=? and pull=? and list!=''", crm_id, pull) or []:
		if row["list"] not in held:
			continue
		key = json.decode(row["key"])
		if type(key) == "list":
			key = tuple(key)
		held[row["list"]][key] = True
	return held

# schema_stray(survivors) removes the attachment rows a part stored on an object
# or comment a purge removed beside it: attachments carry no foreign key, so
# nothing else stops one outliving what it is attached to.
def schema_stray(survivors):
	ids = [id for id in survivors["attachments"] if type(id) == "string" and id]
	for start in range(0, len(ids), SCHEMA_BATCH):
		batch = ids[start:start + SCHEMA_BATCH]
		mochi.db.execute("delete from attachments where entity!='' and id in (" + ", ".join(["?"] * len(batch)) + ") and ((kind='object' and object not in (select id from objects)) or (kind='comment' and object not in (select id from comments)))", batch)

# schema_outcome(reply) -> "unanswered" when a part could not be fetched at all,
# "failed" when the owner answered with a refusal.
def schema_outcome(reply):
	return "unanswered" if not reply or reply.get("transport") else "failed"

# schema_resume(crm_id, outcome, cursor, parts, attempt, pull) leaves the rest
# of a pull that stopped short to a continuation: at once when its time ran out,
# and after a pause when a part went unanswered, SCHEMA_RETRIES times in a row at
# most. A pull the owner refused, or whose retries ran out, waits for the next
# resync, and its rows go.
def schema_resume(crm_id, outcome, cursor, parts, attempt=0, pull=None):
	pull = schema_pull(pull)
	data = {"crm": crm_id, "cursor": cursor, "parts": parts, "pull": pull}
	if outcome == "stopped":
		data["attempt"] = 0
		mochi.schedule.after("schedule_schema", data, 0)
	elif outcome == "unanswered" and attempt < SCHEMA_RETRIES:
		data["attempt"] = attempt + 1
		mochi.schedule.after("schedule_schema", data, 60 * (attempt + 1) * (attempt + 1))
	else:
		schema_end(crm_id, pull)

# schema_completed(crm_id): a pull reached the last part, so the replica holds
# the owner's state and its idle timer starts again.
def schema_completed(crm_id):
	mochi.broadcast.touch(crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/resynced", "crm": crm_id})

# schedule_schema(e): a continuation of a pull schema_resume left, taking the
# parts from its cursor on, within its own time. Its own survivors are only the
# parts it took, so what it prunes comes from holdings (schema_finish). One whose
# pull is no longer the replica's own - the subscription it belonged to was
# dropped, even if a new one has since taken its place, or a newer pull replaced
# it - does nothing.
def schedule_schema(e):
	if e.source != "schedule":
		return
	crm_id = e.data.get("crm", "")
	cursor = e.data.get("cursor")
	if not mochi.text.valid(crm_id, "entity") or not schema_cursor(cursor):
		return
	row = mochi.db.row("select server from crms where id=? and owner=0", crm_id)
	if not row:
		return
	pull = schema_pull(e.data.get("pull"))
	if not schema_current(crm_id, pull):
		return
	parts = schema_count(e.data.get("parts"))
	attempt = schema_count(e.data.get("attempt"))
	started = mochi.time.now()
	row_set("crms", "id=?", [crm_id], {"synced": started})
	server = row["server"] or ""
	peer = mochi.remote.peer(server) if server else ""
	schema = schema_fetch(crm_id, peer, cursor)
	if not schema or schema.get("error"):
		schema_resume(crm_id, schema_outcome(schema), cursor, parts, attempt, pull)
		return
	if insert_schema(crm_id, schema, peer, started, None, parts, SCHEMA_TIME, pull):
		schema_completed(crm_id)

# schema_count(value) -> a count carried in a schedule's data, or 0.
def schema_count(value):
	if type(value) in ["int", "float"] and value > 0:
		return int(value)
	return 0

# schema_holdings(crm_id) -> what the replica holds of the CRM, keyed as
# schema_prune compares it: the rows a complete pull may prune.
def schema_holdings(crm_id):
	held = {}
	for name in SCHEMA_HELD:
		held[name] = {}
	for row in mochi.db.rows("select id from objects where crm=?", crm_id) or []:
		held["objects"][row["id"]] = True
	for row in mochi.db.rows("select c.id as id from comments c join objects o on c.object=o.id where o.crm=?", crm_id) or []:
		held["comments"][row["id"]] = True
	for row in mochi.db.rows("select v.object as object, v.field as field from \"values\" v join objects o on o.id=v.object where o.crm=?", crm_id) or []:
		held["values"][(row["object"], row["field"])] = True
	for row in mochi.db.rows("select id from attachments where entity!='' and ((kind='object' and object in (select id from objects where crm=?)) or (kind='comment' and object in (select c.id from comments c join objects o on o.id=c.object where o.crm=?)))", crm_id, crm_id) or []:
		held["attachments"][row["id"]] = True
	for row in mochi.db.rows("select source, target, linktype from links where crm=?", crm_id) or []:
		held["links"][(row["source"], row["target"], row["linktype"])] = True
	for row in mochi.db.rows("select id from classes where crm=?", crm_id) or []:
		held["classes"][row["id"]] = True
	for row in mochi.db.rows("select class, id from fields where crm=?", crm_id) or []:
		held["fields"][(row["class"], row["id"])] = True
	for row in mochi.db.rows("select class, field, id from options where crm=?", crm_id) or []:
		held["options"][(row["class"], row["field"], row["id"])] = True
	for row in mochi.db.rows("select class, parent from hierarchy where crm=?", crm_id) or []:
		held["hierarchy"][(row["class"], row["parent"])] = True
	for row in mochi.db.rows("select id from views where crm=?", crm_id) or []:
		held["views"][row["id"]] = True
	for row in mochi.db.rows("select view, field from view_fields where crm=?", crm_id) or []:
		held["view_fields"][(row["view"], row["field"])] = True
	for row in mochi.db.rows("select view, class from view_classes where crm=?", crm_id) or []:
		held["view_classes"][(row["view"], row["class"])] = True
	for row in mochi.db.rows("select id from subscribers where crm=?", crm_id) or []:
		held["members"][row["id"]] = True
	return held

# field_limits(field) -> dict: the validation limits and display affixes a field
# row from the owner carries - min, max, pattern, prefix, suffix and format as
# text, minlength and maxlength as whole numbers - each only when present and of
# its type, so a row without them leaves the replica's own.
def field_limits(field):
	limits = {}
	for name in FIELD_LIMITS:
		if name in FIELD_NUMBERS:
			continue
		value = field.get(name)
		if type(value) == "string" and len(value) <= 1000:
			limits[name] = value
	for name in FIELD_LIMITS:
		if name not in FIELD_NUMBERS:
			continue
		value = field.get(name)
		if type(value) == "float" and value >= 0 and value < 1000000000 and value == int(value):
			value = int(value)
		if type(value) == "int" and value >= 0 and value < 1000000000:
			limits[name] = value
	return limits

# The rows a replica writes from what its owner sends, each column reduced to
# the type it holds (text, number), or None for one that names no row. Every
# path a copy learns its design by - a schema part, the sync batch, the live
# events - writes through these, so they cannot differ in what they accept.

# class_row(crm_id, c) -> a classes row.
def class_row(crm_id, c):
	c = record(c)
	id = text(c.get("id"))
	if not id:
		return None
	return {"crm": crm_id, "id": id, "name": text(c.get("name")), "rank": number(c.get("rank")), "title": text(c.get("title"))}

# field_row(crm_id, class_id, f) -> a fields row, every column of FIELD_COLUMNS
# but the constraints and affixes the owner left out (field_limits), each
# reduced to the type it holds: FIELD_NUMBERS whole numbers, the rest text.
def field_row(crm_id, class_id, f):
	f = record(f)
	id = text(f.get("id"))
	if not text(class_id) or not id:
		return None
	row = {"crm": crm_id, "class": class_id, "id": id}
	for column in FIELD_COLUMNS:
		if column in row or column in FIELD_LIMITS:
			continue
		if column in FIELD_NUMBERS:
			row[column] = number(f.get(column), 1 if column in ["card", "rows"] else 0)
		else:
			row[column] = text(f.get(column))
	row["fieldtype"] = row["fieldtype"] or "text"
	row.update(field_limits(f))
	return row

# option_row(crm_id, class_id, field_id, o) -> an options row.
def option_row(crm_id, class_id, field_id, o):
	o = record(o)
	id = text(o.get("id"))
	if not text(class_id) or not text(field_id) or not id:
		return None
	return {"crm": crm_id, "class": class_id, "field": field_id, "id": id, "name": text(o.get("name")), "colour": text(o.get("colour")) or "#94a3b8", "icon": text(o.get("icon")), "rank": number(o.get("rank"))}

# view_row(crm_id, v) -> a views row.
def view_row(crm_id, v):
	v = record(v)
	id = text(v.get("id"))
	if not id:
		return None
	return {"crm": crm_id, "id": id, "name": text(v.get("name")), "viewtype": text(v.get("viewtype")) or "board",
		"filter": text(v.get("filter")), "columns": text(v.get("columns")), "rows": text(v.get("rows")),
		"sort": text(v.get("sort")), "direction": text(v.get("direction")) or "asc", "rank": number(v.get("rank")),
		"border": text(v.get("border"))}

# field_merge(row, guard=None) writes a field row a replica's owner sent,
# under guard when given (row_merge). A field that becomes a user field here
# keeps only the values that are entity ids: a value is checked against its
# field's type as it lands (value_refused), and a value that landed while the
# owner had the field as text would otherwise be rendered as a person.
def field_merge(row, guard=None):
	if not row:
		return
	before = mochi.db.row("select fieldtype from fields where crm=? and class=? and id=?", row["crm"], row["class"], row["id"])
	row_merge("fields", ["crm", "class", "id"], row, None, guard)
	if row["fieldtype"] == "user" and (not before or before["fieldtype"] != "user"):
		user_field_blank(row["crm"], row["class"], row["id"])

# user_field_blank(crm_id, class_id, field_id) removes every value of a user
# field that is not an entity id.
def user_field_blank(crm_id, class_id, field_id):
	for v in mochi.db.rows("select v.object as object, v.value as value from \"values\" v join objects o on o.id=v.object where o.crm=? and o.class=? and v.field=? and v.value!=''", crm_id, class_id, field_id) or []:
		if not mochi.text.valid(v["value"], "entity"):
			row_remove("values", "object=? and field=?", [v["object"], field_id])

# value_write(crm_id, object_id, field, value, handle=None, guard=None) ->
# whether it wrote a value the owner sent onto an object of a replica: the one
# writer every subscriber path uses, a schema part's, the sync batch's,
# object/create's and values/update's. A value is a string, and a user field's
# an entity id or nothing (value_refused); anything else is skipped.
def value_write(crm_id, object_id, field, value, handle=None, guard=None):
	if type(field) != "string" or not field or type(value) != "string":
		return False
	if value_refused(crm_id, object_id, field, value, handle):
		return False
	return row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": value}, handle, guard)

# member_store(crm_id, id, name) records a member of the owner's roster on a
# replica, keeping the place it already has. member_owner(crm_id, id) marks
# which member owns the CRM: its row sorts first (subscribed 0), which is the
# row get_owner_identity, crm_owner_name and the CRM list read. Written only
# while the replica is held, as the schema's rows are.
def member_store(crm_id, id, name):
	if not mochi.text.valid(text(id), "entity"):
		return False
	name = text(name)
	if name and not mochi.text.valid(name, "display"):
		name = ""
	mochi.db.execute("insert into subscribers (crm, id, name, subscribed) select ?, ?, ?, ? where exists (select 1 from crms where id=? and owner=0) on conflict (crm, id) do update set name=excluded.name", crm_id, id, name, mochi.time.now() or 1, crm_id)
	return True

def member_owner(crm_id, id):
	if not mochi.text.valid(text(id), "entity"):
		return
	mochi.db.execute("update subscribers set subscribed=? where crm=? and subscribed=0 and id!=?", mochi.time.now() or 1, crm_id, id)
	mochi.db.execute("insert into subscribers (crm, id, name, subscribed) select ?, ?, '', 0 where exists (select 1 from crms where id=? and owner=0) on conflict (crm, id) do update set subscribed=0", crm_id, id, crm_id)

# schema_merge(crm_id, schema, survivors) -> whether it skipped a late row:
# applies one part, or a whole schema, recording every row it names in
# survivors. A whole schema from an owner that predates parts nests values,
# comments, activity and attachments in each object; a part sends them as flat
# lists of their own.
#
# A row whose parent the replica does not hold (the class of a field, hierarchy
# rule, view class or object, the field of an option) is late: the owner made
# the parent after the part that would have carried it was read. Its foreign key
# would abort the merge, so it is skipped, and stays among the survivors so a
# copy the replica already holds is not pruned.
def schema_merge(crm_id, schema, survivors):
	late = False
	# Reconcile the crm row itself (name / description). UPDATE only -
	# the crm row was created at subscribe time and we never want to
	# flip owner away from 0 on a resync. Idempotent when the
	# subscriber's row already matches.
	crm_data = schema.get("crm")
	if type(crm_data) == "dict":
		updates = {key: crm_data[key] for key in ["name", "description"] if type(crm_data.get(key)) == "string"}
		if updates:
			row_set("crms", "id=? and owner=0", [crm_id], updates)
		# Which member owns the CRM, so the copy names the right person.
		if crm_data.get("owner"):
			member_owner(crm_id, crm_data["owner"])
	for c in sequence(schema.get("classes")):
		row = class_row(crm_id, c)
		if row:
			row_merge("classes", ["crm", "id"], row, None, schema_guard("crms", "id=? and owner=0", crm_id))
	for f in sequence(schema.get("fields")):
		f = record(f)
		if not schema_class(crm_id, f.get("class", "")):
			late = True
			continue
		field_merge(field_row(crm_id, f["class"], f), schema_guard("classes", "crm=? and id=?", crm_id, f["class"]))
	for o in sequence(schema.get("options")):
		row = option_row(crm_id, record(o).get("class"), record(o).get("field"), o)
		if not row:
			continue
		if not mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, row["class"], row["field"]):
			late = True
			continue
		row_merge("options", ["crm", "class", "field", "id"], row, None, schema_guard("fields", "crm=? and class=? and id=?", crm_id, row["class"], row["field"]))
	for h in sequence(schema.get("hierarchy")):
		h = record(h)
		if not schema_class(crm_id, h.get("class", "")):
			late = True
			continue
		for parent in sequence(h.get("parents")):
			if type(parent) != "string":
				continue
			# (crm, class, parent) is the full primary key; there is
			# no editable payload to reconcile, so ignore is right.
			row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": h["class"], "parent": parent}, None, schema_guard("classes", "crm=? and id=?", crm_id, h["class"]))
	for v in sequence(schema.get("views")):
		row = view_row(crm_id, v)
		if not row:
			continue
		view_id = row["id"]
		row_merge("views", ["crm", "id"], row, None, schema_guard("crms", "id=? and owner=0", crm_id))
		fields_csv = v.get("fields", "")
		if type(fields_csv) == "string" and fields_csv:
			rank = 0
			for field_id in fields_csv.split(","):
				if field_id:
					# view_fields has an editable rank; reconcile it.
					row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field_id, "rank": rank}, None, schema_guard("views", "crm=? and id=?", crm_id, view_id))
					rank += 1
		classes_csv = v.get("classes", "")
		if type(classes_csv) == "string" and classes_csv:
			for class_id in classes_csv.split(","):
				if not class_id:
					continue
				if not schema_class(crm_id, class_id):
					late = True
					continue
				# (crm, view, class) has no payload columns.
				row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": class_id}, None, schema_guard("views v join classes c on c.crm=v.crm", "v.crm=? and v.id=? and c.id=?", crm_id, view_id, class_id))
	for name in survivors["design"]:
		survivors["design"][name].extend(sequence(schema.get(name)))
	for obj in sequence(schema.get("objects")):
		if type(obj) != "dict":
			continue
		object_id = obj.get("id", "")
		if not identifier(object_id):
			continue
		survivors["objects"][object_id] = True
		# Never adopt/reassign an object that already belongs to another crm, or
		# an id a comment holds - a malicious owner's dump could otherwise
		# hijack our other crms' rows.
		if foreign_object(object_id, crm_id):
			continue
		# A late object is skipped; the rows nested in it below are still
		# named, and land only on an object the replica holds. One the replica
		# holds at a later version than the part's, which a change broadcast
		# since the owner read the part has reached, keeps its row
		# (version_take), checked in the same statement as the write.
		version = owner_version(obj.get("version"))
		if schema_class(crm_id, obj.get("class", "")):
			row = {"id": object_id, "crm": crm_id, "class": obj["class"], "parent": text(obj.get("parent")), "rank": rank_copy(obj.get("rank")), "created": number(obj.get("created")), "updated": number(obj.get("updated"))}
			guard = schema_guard("classes", "crm=? and id=?", crm_id, obj["class"])
			if version != None:
				row["version"] = version
				guard = (guard[0] + " and not exists (select 1 from objects where id=? and version>?)", guard[1] + [object_id, version])
			object_merge(row, guard)
		else:
			late = True
		schema_attachments(crm_id, survivors, object_id, obj.get("attachments"), "object")
		values = obj.get("values")
		if type(values) == "dict":
			for field in values:
				schema_value(crm_id, survivors, {"object": object_id, "field": field, "value": values[field], "version": version})
		if schema_comments(crm_id, survivors, [dict(c, object=object_id) for c in sequence(obj.get("comments")) if type(c) == "dict"]):
			late = True
		for act in sequence(obj.get("activity")):
			if type(act) == "dict":
				schema_activity(crm_id, dict(act, object=object_id))
	for v in sequence(schema.get("values")):
		if type(v) == "dict":
			schema_value(crm_id, survivors, v)
	if schema_comments(crm_id, survivors, [c for c in sequence(schema.get("comments")) if type(c) == "dict"]):
		late = True
	for act in sequence(schema.get("activity")):
		if type(act) == "dict":
			schema_activity(crm_id, act)
	containers = {}
	for att in sequence(schema.get("attachments")):
		if type(att) == "dict" and type(att.get("object")) == "string":
			containers.setdefault(att["object"], []).append(att)
	for container in containers:
		# The table holding the container decides its kind, never the row's
		# claim; an id both tables hold in the CRM answers to neither.
		kinds = [kind for kind in attachment_kinds if container_in_crm(container, kind, crm_id)]
		schema_attachments(crm_id, survivors, container, containers[container], kinds[0] if len(kinds) == 1 else None)
	for l in sequence(schema.get("links")):
		if type(l) != "dict":
			continue
		source = text(l.get("source"))
		target = text(l.get("target"))
		# A type the link handlers do not know is read as they read it: a link
		# stored under it could not be matched by a delete.
		linktype = link_type(l.get("linktype"))
		survivors["links"][(source, target, linktype)] = True
		# (crm, source, target, linktype) is the full key; links are
		# created/deleted, never edited in place.
		if not link_endpoints_bound(crm_id, source, target):
			continue
		row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": source, "target": target, "linktype": linktype, "created": 0}, None, schema_guard("objects s join objects t on t.crm=s.crm", "s.crm=? and s.id=? and t.id=?", crm_id, source, target))
	# The roster, each member as the owner names them.
	for m in sequence(schema.get("members")):
		m = record(m)
		if member_store(crm_id, m.get("id"), m.get("name")):
			survivors["members"][m["id"]] = True
	return late

# schema_comments(crm_id, survivors, comments) -> whether any comment was late:
# applies a part's comments, a reply only once the comment it answers is held.
# Within the part a reply can come before what it answers, so each pass applies
# what it can until a pass applies nothing; what is left answers a comment not
# held yet, which a later part or the fresh pull a late pull asks for brings.
def schema_comments(crm_id, survivors, comments):
	pending = comments
	for _ in range(len(comments)):
		if not pending:
			break
		waiting = [c for c in pending if schema_comment(crm_id, survivors, c)]
		if len(waiting) == len(pending):
			break
		pending = waiting
	return len(pending) > 0

# schema_guard(source, where, arguments...) -> the condition, and its
# arguments, a part's row is written under (row_merge): the parent its foreign
# key needs is held. Checked in the statement that writes the row, so a purge
# beside the merge, between a separate check and the write, cannot leave the
# write to fail on the key.
def schema_guard(source, where, *arguments):
	return "exists (select 1 from " + source + " where " + where + ")", list(arguments)

# Does the replica hold this class of the CRM? A field, hierarchy rule, view
# class or object lands only on one it does.
def schema_class(crm_id, class_id):
	return type(class_id) == "string" and class_id != "" and mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id)

# Does the object belong to this CRM? A value, comment or activity row lands
# only on one that does.
def schema_object(crm_id, object_id):
	return type(object_id) == "string" and object_id != "" and mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id)

def schema_value(crm_id, survivors, v):
	field = v.get("field")
	if type(field) != "string" or not field:
		return
	survivors["values"][(text(v.get("object")), field)] = True
	if not schema_object(crm_id, v.get("object", "")):
		return
	# A value read at the object's version lands only on a copy not past it, in
	# the same statement: a change broadcast since the owner read the part
	# stands (version_take). From an owner that predates versions, every value
	# lands.
	version = owner_version(v.get("version"))
	guard = schema_guard("objects", "id=?", v["object"]) if version == None else schema_guard("objects", "id=? and version<=?", v["object"], version)
	value_write(crm_id, v["object"], field, v.get("value"), None, guard)

# schema_comment(crm_id, survivors, c) -> whether the comment is late: it
# answers a comment the replica does not hold yet (comment_parent_check), and is
# left for a pass or a pull that has it. One that answers itself, another
# object's comment, or closes a loop of replies is refused.
def schema_comment(crm_id, survivors, c):
	comment_id = c.get("id", "")
	if not identifier(comment_id):
		return False
	survivors["comments"][comment_id] = True
	# Skip a comment id that already belongs to another crm's object, or that
	# an object holds.
	if foreign_comment(comment_id, crm_id):
		return False
	if not schema_object(crm_id, c.get("object", "")):
		return False
	parent = text(c.get("parent"))
	place = comment_parent_check(comment_id, c["object"], parent)
	if place == "late":
		return True
	if place != "ok":
		return False
	comment_merge({"id": comment_id, "object": c["object"], "parent": parent, "author": text(c.get("author")), "name": text(c.get("name")), "content": text(c.get("content")), "created": number(c.get("created")), "edited": number(c.get("edited"))}, schema_guard("objects", "id=?", c["object"]))
	schema_attachments(crm_id, survivors, comment_id, c.get("attachments"), "comment")
	return False

def schema_activity(crm_id, act):
	if not identifier(act.get("id")):
		return
	if not schema_object(crm_id, act.get("object", "")):
		return
	# Activity is append-only; ignore is correct. Written while its object is
	# held, as schema_guard writes the other rows.
	mochi.db.execute(
		"insert or ignore into activity (id, object, user, action, field, oldvalue, newvalue, created) select ?, ?, ?, ?, ?, ?, ?, ? where exists (select 1 from objects where id=?)",
		act["id"], act["object"], text(act.get("user")),
		text(act.get("action")), text(act.get("field")),
		text(act.get("oldvalue")), text(act.get("newvalue")),
		number(act.get("created")), act["object"]
	)

# Attachments land only on an object or comment of this CRM, as the kind the
# caller knows container to be; None stores nothing.
def schema_attachments(crm_id, survivors, container, rows, kind):
	rows = sequence(rows)
	if not rows:
		return
	for att in rows:
		if type(att) == "dict":
			survivors["attachments"][text(att.get("id"))] = True
	if not kind or not container_in_crm(container, kind, crm_id):
		return
	attachment_store(rows, crm_id, container, kind)

# schema_named(survivors) -> the key of every row a pull's parts named, list by
# list (SCHEMA_HELD) as schema_holdings keys what the replica holds.
def schema_named(survivors):
	named = {"objects": survivors["objects"], "comments": survivors["comments"], "values": survivors["values"], "attachments": survivors["attachments"], "links": survivors["links"], "members": survivors["members"],
		"classes": {}, "fields": {}, "options": {}, "hierarchy": {}, "views": {}, "view_fields": {}, "view_classes": {}}
	design = survivors["design"]
	for c in sequence(design.get("classes")):
		named["classes"][text(record(c).get("id"))] = True
	for f in sequence(design.get("fields")):
		f = record(f)
		named["fields"][(text(f.get("class")), text(f.get("id")))] = True
	for o in sequence(design.get("options")):
		o = record(o)
		named["options"][(text(o.get("class")), text(o.get("field")), text(o.get("id")))] = True
	for h in sequence(design.get("hierarchy")):
		h = record(h)
		for parent in sequence(h.get("parents")):
			named["hierarchy"][(text(h.get("class")), text(parent))] = True
	for v in sequence(design.get("views")):
		v = record(v)
		view_id = text(v.get("id"))
		named["views"][view_id] = True
		for field_id in text(v.get("fields")).split(","):
			if field_id:
				named["view_fields"][(view_id, field_id)] = True
		for class_id in text(v.get("classes")).split(","):
			if class_id:
				named["view_classes"][(view_id, class_id)] = True
	return named

# schema_prune(crm_id, survivors, held, pull) reconciles deletions once a
# complete schema has landed: the schema is the owner's full state, so a row the
# replica held before the pull began (held) that it does not name was deleted
# owner-side. A row that arrived while the pull ran is never pruned, since a
# part read before it existed could not name it. Runs after the upserts,
# children before parents, so a mid-apply failure leaves only surplus rows.
# Watchers and activity are cleaned only through the stray-object cascade.
#
# Nothing goes once a live event has cancelled the prune (schema_cancel). The
# rows keyed by what they hold (values, links, the design) are deleted under
# schema_permit in the statement itself, since the owner can put one back while
# the prune runs; an object, comment or attachment, keyed by an id made once,
# cannot come back, so the permit is checked as each goes.
def schema_prune(crm_id, survivors, held, pull):
	named = schema_named(survivors)
	condition, arguments = schema_permit(crm_id, pull)

	def permitted():
		return mochi.db.exists("select 1 where " + condition, arguments)

	def stray(table, key):
		return key not in named[table] and key in held[table]

	def remove(table, where, args):
		row_remove(table, "(" + where + ") and " + condition, list(args) + arguments)

	if not permitted():
		return
	for row in (mochi.db.rows("select id from objects where crm=?", crm_id) or []):
		if stray("objects", row["id"]) and permitted():
			delete_object_local(crm_id, row["id"], True)
	for row in (mochi.db.rows("select c.id from comments c join objects o on c.object=o.id where o.crm=?", crm_id) or []):
		if stray("comments", row["id"]) and permitted():
			prune_attachments(row["id"], crm_id, True, "comment")
			row_remove("comments", "id=?", [row["id"]])
	# Values the owner cleared, and attachments the owner deleted, on surviving
	# objects and comments. Only references to files hosted elsewhere go; never
	# this replica's own uploads (see prune_attachments).
	for row in (mochi.db.rows("select v.object as object, v.field as field from \"values\" v join objects o on o.id=v.object where o.crm=?", crm_id) or []):
		if stray("values", (row["object"], row["field"])):
			remove("values", "object=? and field=?", [row["object"], row["field"]])
	for row in (mochi.db.rows("select id from attachments where entity!='' and ((kind='object' and object in (select id from objects where crm=?)) or (kind='comment' and object in (select c.id from comments c join objects o on o.id=c.object where o.crm=?)))", crm_id, crm_id) or []):
		if stray("attachments", row["id"]) and permitted():
			attachment_delete(row["id"])
	for row in (mochi.db.rows("select view, field from view_fields where crm=?", crm_id) or []):
		if stray("view_fields", (row["view"], row["field"])):
			remove("view_fields", "crm=? and view=? and field=?", [crm_id, row["view"], row["field"]])
	for row in (mochi.db.rows("select view, class from view_classes where crm=?", crm_id) or []):
		if stray("view_classes", (row["view"], row["class"])):
			remove("view_classes", "crm=? and view=? and class=?", [crm_id, row["view"], row["class"]])
	for row in (mochi.db.rows("select id from views where crm=?", crm_id) or []):
		if stray("views", row["id"]):
			remove("views", "crm=? and id=?", [crm_id, row["id"]])
	for row in (mochi.db.rows("select class, field, id from options where crm=?", crm_id) or []):
		if stray("options", (row["class"], row["field"], row["id"])):
			remove("options", "crm=? and class=? and field=? and id=?", [crm_id, row["class"], row["field"], row["id"]])
	for row in (mochi.db.rows("select class, id from fields where crm=?", crm_id) or []):
		if stray("fields", (row["class"], row["id"])):
			remove("fields", "crm=? and class=? and id=?", [crm_id, row["class"], row["id"]])
	for row in (mochi.db.rows("select class, parent from hierarchy where crm=?", crm_id) or []):
		if stray("hierarchy", (row["class"], row["parent"])):
			remove("hierarchy", "crm=? and class=? and parent=?", [crm_id, row["class"], row["parent"]])
	for row in (mochi.db.rows("select id from classes where crm=?", crm_id) or []):
		if stray("classes", row["id"]):
			remove("classes", "crm=? and id=?", [crm_id, row["id"]])
	for row in (mochi.db.rows("select source, target, linktype from links where crm=?", crm_id) or []):
		if stray("links", (row["source"], row["target"], row["linktype"])):
			remove("links", "crm=? and source=? and target=? and linktype=?", [crm_id, row["source"], row["target"], row["linktype"]])
	# Members who have left since the replica learned of them.
	for row in (mochi.db.rows("select id from subscribers where crm=?", crm_id) or []):
		if stray("members", row["id"]):
			remove("subscribers", "crm=? and id=?", [crm_id, row["id"]])

# send_crm_data(crm_id, subscribers): send the whole CRM to each of subscribers
# (identity ids), as one sync batch read and built once for them all.
def send_crm_data(crm_id, subscribers):
	if not subscribers:
		return

	# One batched read, reshaped: classes carry their fields (with options)
	# and parents, so the subscriber can apply them top-down.
	dump = crm_dump(crm_id)
	parents_map = {}
	for rule in dump["hierarchy"]:
		parents_map[rule["class"]] = rule["parents"]
	options_map = {}
	for o in dump["options"]:
		options_map.setdefault((o["class"], o["field"]), []).append({"id": o["id"], "name": o["name"], "colour": o["colour"], "icon": o["icon"], "rank": o["rank"]})
	fields_map = {}
	for f in dump["fields"]:
		field_data = {column: f[column] for column in FIELD_COLUMNS if column != "class"}
		if (f["class"], f["id"]) in options_map:
			field_data["options"] = options_map[(f["class"], f["id"])]
		fields_map.setdefault(f["class"], []).append(field_data)
	classes = []
	for t in dump["classes"]:
		class_data = {"id": t["id"], "name": t["name"], "rank": t["rank"], "title": t["title"], "fields": fields_map.get(t["id"], [])}
		if t["id"] in parents_map:
			class_data["parents"] = parents_map[t["id"]]
		classes.append(class_data)
	# Core refuses a frame over 16 MB and decodes at most 10,000 elements in
	# one array, and a CRM of a few thousand objects with comments and activity
	# exceeds that in one message: the objects go in chunks of at most
	# SYNC_CHUNK objects and SCHEMA_ROWS rows, the links in chunks of their
	# own. Messages may arrive in any order and an object lands only on a class
	# the subscriber holds, so every chunk carries the design, and the roster
	# with the member who owns the CRM. event_sync_batch marks the replica
	# populated once every chunk of the sync has landed.
	# A roster longer than a part may carry is left to the subscriber's own
	# pull, which pages it (SCHEMA_SPECS["members"]).
	chunks = batch_chunks(dump["objects"], dump["links"])
	members = roster(crm_id)
	owner = get_owner_identity(crm_id)
	sync = mochi.uid()
	payloads = []
	for index, chunk in enumerate(chunks):
		payload = {
			"crm": crm_id,
			"classes": classes,
			"views": dump["views"],
			"objects": chunk["objects"],
			"links": chunk["links"],
			"owner": owner,
			"chunk": batch_chunk(sync, index, len(chunks)),
		}
		if len(members) <= SCHEMA_ROWS:
			payload["members"] = members
		payloads.append(payload)
	for subscriber in subscribers:
		h = p2p_headers(crm_id, subscriber, "sync/batch")
		for payload in payloads:
			mochi.message.send(h, payload)

# batch_fragments(obj) -> [(fragment, rows, bytes)]: an object of crm_dump cut
# into pieces of at most SCHEMA_ROWS rows and about SCHEMA_BYTES bytes, each
# piece carrying the object's own row and a share of its values, comments and
# activity, so an object with a long history still travels. A subscriber merges
# every piece onto the one object. Attachments stay behind: a batch never
# applied them, and the schema carries them.
def batch_fragments(obj):
	base = {"id": obj["id"], "class": obj["class"], "parent": obj["parent"], "rank": obj["rank"], "created": obj["created"], "updated": obj["updated"], "version": obj["version"]}
	items = []
	values = obj.get("values") or {}
	for field in values:
		items.append(("values", (field, values[field]), 64 + len(str(values[field]))))
	for c in obj.get("comments") or []:
		comment = {k: c[k] for k in c if k != "attachments"}
		comment["object"] = obj["id"]
		items.append(("comments", comment, 64 + len(c.get("content", ""))))
	for act in obj.get("activity") or []:
		items.append(("activity", act, 64 + len(act.get("oldvalue", "")) + len(act.get("newvalue", ""))))
	fragments = []
	current = dict(base)
	rows = 1
	size = 64
	for kind, item, cost in items:
		if rows > 1 and (rows >= SCHEMA_ROWS or size + cost > SCHEMA_BYTES):
			fragments.append((current, rows, size))
			current = dict(base)
			rows = 1
			size = 64
		if kind == "values":
			current.setdefault("values", {})[item[0]] = item[1]
		else:
			current.setdefault(kind, []).append(item)
		rows += 1
		size += cost
	fragments.append((current, rows, size))
	return fragments

# batch_chunks(objects, links) -> [{objects, links}]: the sync batch cut into
# chunks within SYNC_CHUNK objects, SCHEMA_ROWS rows and about SCHEMA_BYTES
# bytes, objects first, then the links once every object they join has gone.
# Always at least one.
def batch_chunks(objects, links):
	chunks = []
	current = []
	rows = 0
	size = 0
	for obj in objects:
		for fragment, fragment_rows, fragment_size in batch_fragments(obj):
			if current and (len(current) >= SYNC_CHUNK or rows + fragment_rows > SCHEMA_ROWS or size + fragment_size > SCHEMA_BYTES):
				chunks.append({"objects": current, "links": []})
				current = []
				rows = 0
				size = 0
			current.append(fragment)
			rows += fragment_rows
			size += fragment_size
	if current or not chunks:
		chunks.append({"objects": current, "links": []})
	# Messages may arrive in any order, and a link lands only between objects
	# the subscriber holds, so each chunk of links carries the rows of the
	# objects it joins, at most two per link.
	rows = {}
	for obj in objects:
		rows[obj["id"]] = batch_fragments({k: obj[k] for k in obj if k not in ["values", "comments", "activity", "attachments"]})[0][0]
	step = SCHEMA_ROWS // 3 or 1
	for start in range(0, len(links), step):
		chunk = links[start:start + step]
		ends = {}
		for l in chunk:
			for end in [l["source"], l["target"]]:
				if end in rows:
					ends[end] = rows[end]
		chunks.append({"objects": list(ends.values()), "links": chunk})
	return chunks

# The most chunks one sync batch may name.
BATCH_CHUNKS = 100000
# How long a sync's chunks are held waiting for the rest. A sync that has not
# completed in that time lost a chunk; its rows go when the next chunk of the
# CRM arrives.
BATCH_AGE = 86400

# batch_chunk(sync, index, total) -> the chunk marker of one message of a sync
# batch: which sync it belongs to, where it falls, and how many there are.
# final names the sync's last chunk by index: a subscriber that predates
# counting marks its replica populated on it, whatever order the chunks came in.
def batch_chunk(sync, index, total):
	return {"sync": sync, "index": index, "total": total, "final": index == total - 1}

# batch_complete(key, chunk) -> whether this batch completes the owner's sync,
# recording it among the chunks held for key. Messages may arrive in any order,
# so a replica is complete only once it holds every chunk of one sync; chunks
# of another sync, an earlier or a later one, never count toward it, and
# completing one clears only its own rows. An owner that predates counting
# marks only its final chunk, and one that predates chunks sends one batch.
def batch_complete(key, chunk):
	if type(chunk) != "dict":
		return True
	total = chunk.get("total")
	if total == None:
		return chunk.get("final", True) == True
	index = chunk.get("index")
	sync = chunk.get("sync")
	if type(total) != "int" or type(index) != "int" or total < 1 or total > BATCH_CHUNKS or index < 0 or index >= total:
		return False
	if type(sync) != "string" or not mochi.text.valid(sync, "id"):
		return False
	now = mochi.time.now()
	mochi.db.execute("delete from chunks where crm=? and sync!=? and created<?", key, sync, now - BATCH_AGE)
	mochi.db.execute("insert or ignore into chunks ( crm, sync, chunk, created ) values ( ?, ?, ?, ? )", key, sync, index, now)
	if mochi.db.row("select count(*) as held from chunks where crm=? and sync=?", key, sync)["held"] < total:
		return False
	mochi.db.execute("delete from chunks where crm=? and sync=?", key, sync)
	return True

# snapshot_seconds: how long after the owner last sent a subscriber the whole CRM
# a repeated subscribe is answered with nothing. Reading and queueing the whole
# CRM costs the owner far more than the 200-byte event that asks for it; a
# subscriber that genuinely needs it pulls it by bounded schema parts.
snapshot_seconds = 3600

# Handle subscribe event from a remote user
def event_subscribe(e):
	crm_id = e.header("to")

	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		return

	subscriber_id = e.header("from")
	if not mochi.text.valid(subscriber_id, "entity"):
		return
	# The owner's own identity anchors the CRM as its first subscriber
	# (get_owner_identity); a subscribe from it would move that row behind the
	# members who joined since.
	if subscriber_id == get_owner_identity(crm_id):
		return

	# Check subscriber has at least view access
	if not check_crm_access(subscriber_id, crm_id, "view"):
		return

	name = e.content("name")
	if not mochi.text.valid(name, "display"):
		return

	now = mochi.time.now()
	existing = mochi.db.row("select name, sent from subscribers where crm=? and id=?", crm_id, subscriber_id)
	row_merge("subscribers", ["crm", "id"], {"crm": crm_id, "id": subscriber_id, "name": name, "subscribed": now})
	# Record them for replay now rather than waiting for the next broadcast to
	# do it, so a gap opening before that can still be healed.
	mochi.broadcast.subscriber.add(crm_id, subscriber_id)

	# Update crm timestamp
	row_set("crms", "id=?", [crm_id], {"updated": now})
	# Send websocket notification for real-time UI updates
	fingerprint = mochi.entity.fingerprint(crm_id)
	if fingerprint:
		mochi.websocket.write(fingerprint, {"type": "crm/update", "crm": crm_id})

	# The members' copies of the roster learn of a new member, or a new name.
	if not existing or existing["name"] != name:
		broadcast_event(crm_id, "member/add", {"crm": crm_id, "id": subscriber_id, "name": name})

	# Sync all existing crm data to a new subscriber, or to one not sent it
	# within snapshot_seconds; the subscriber's own pull fills its replica
	# meanwhile (action_subscribe).
	if not existing or now - (existing["sent"] or 0) >= snapshot_seconds:
		send_crm_data(crm_id, [subscriber_id])
		row_set("subscribers", "crm=? and id=?", [crm_id, subscriber_id], {"sent": now})

# Handle unsubscribe event from a remote user. The owner's own identity anchors
# the CRM (get_owner_identity) and is never a member that leaves. What a member
# did stays in the activity log: only their watchers go with them
# (subscriber_remove), and the members who remain are told.
def event_unsubscribe(e):
	crm_id = e.header("to")

	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		return

	subscriber_id = e.header("from")
	if not subscriber_id or subscriber_id == get_owner_identity(crm_id):
		return
	# Core's replay record goes even when the row went earlier.
	held = mochi.db.exists("select 1 from subscribers where crm=? and id=?", crm_id, subscriber_id)
	subscriber_remove(crm_id, subscriber_id)
	if not held:
		return
	# Update crm timestamp
	row_set("crms", "id=?", [crm_id], {"updated": mochi.time.now()})
	broadcast_event(crm_id, "member/remove", {"crm": crm_id, "id": subscriber_id})
	# Send websocket notification
	fingerprint = mochi.entity.fingerprint(crm_id)
	if fingerprint:
		mochi.websocket.write(fingerprint, {"type": "crm/update", "crm": crm_id})

# Handle notification that a crm has been deleted by its owner
def event_deleted(e):
	# The deletion notice is sent from the CRM entity itself, so the authenticated
	# sender IS the CRM. Using the from header (not a spoofable content field)
	# stops any peer wiping a CRM we subscribe to.
	crm_id = e.header("from")

	# Only delete if we don't own this crm
	crm = mochi.db.row("select * from crms where id=? and owner=0", crm_id)
	if not crm:
		return

	# Delete all local data for this remote crm — physical purge, so a later
	# re-share imports cleanly (see purge_crm).
	# purge_crm clears the attachments, object and comment alike.
	purge_crm(crm_id)

# Owner revoked our access. Sent from the CRM entity by subscribers_revalidate,
# so the authenticated sender IS the CRM; purge the replica.
def event_access_revoke(e):
	crm_id = e.header("from")

	# Only purge replicas, never a crm we own
	crm = mochi.db.row("select * from crms where id=? and owner=0", crm_id)
	if not crm:
		return

	# purge_crm clears the attachments, object and comment alike.
	purge_crm(crm_id)
# ============================================================================
# Content Sync Event Handlers (received by subscribers)
# ============================================================================

def sequence(value):
	"""A peer-supplied sequence, or empty. Iterating a string or an int raises,
	ending the handler, and a dict yields its keys, which reach the element
	checks looking like data.

	Both types are accepted because core encodes a JSON array as a Starlark
	tuple, not a list (sl_encode, []any -> sl.Tuple), so a list-only test
	discards every payload that arrives over the wire."""
	return value if type(value) in ["list", "tuple"] else []

# Does a sync-batch element carry the keys the merge will index? Indexing with
# [...] raises on a missing key or a non-dict, and Starlark has no try/except,
# so one malformed entry would abort the whole batch.
def sync_element(item, keys):
    if type(item) != "dict":
        return False
    for key in keys:
        if item.get(key) == None:
            return False
    return True


# batch_design_reconcile(crm_id, e) removes, for each class a complete sync
# batch names with its parents, the parents it no longer names, and for each
# view it names, the fields and classes the view no longer names; and, from an
# owner that sends its roster, the members it no longer names.
def batch_design_reconcile(crm_id, e):
	for t in sequence(e.content("classes")):
		if not sync_element(t, ["id", "name"]) or type(t["id"]) != "string":
			continue
		parents = [p for p in sequence(t.get("parents")) if type(p) == "string"]
		if not parents:
			continue
		for row in mochi.db.rows("select parent from hierarchy where crm=? and class=?", crm_id, t["id"]) or []:
			if row["parent"] not in parents:
				row_remove("hierarchy", "crm=? and class=? and parent=?", [crm_id, t["id"], row["parent"]])
	for v in sequence(e.content("views")):
		if not sync_element(v, ["id", "name", "viewtype"]) or type(v["id"]) != "string":
			continue
		fields = text(v.get("fields")).split(",")
		for row in mochi.db.rows("select field from view_fields where crm=? and view=?", crm_id, v["id"]) or []:
			if row["field"] not in fields:
				row_remove("view_fields", "crm=? and view=? and field=?", [crm_id, v["id"], row["field"]])
		classes = text(v.get("classes")).split(",")
		for row in mochi.db.rows("select class from view_classes where crm=? and view=?", crm_id, v["id"]) or []:
			if row["class"] not in classes:
				row_remove("view_classes", "crm=? and view=? and class=?", [crm_id, v["id"], row["class"]])
	members = e.content("members")
	if type(members) in ["list", "tuple"]:
		named = {text(record(m).get("id")): True for m in members}
		for row in mochi.db.rows("select id from subscribers where crm=?", crm_id) or []:
			if row["id"] not in named:
				row_remove("subscribers", "crm=? and id=?", [crm_id, row["id"]])

# batch_comments(crm_id, object_id, comments, now) -> whether a comment was
# left out because it answers one the replica does not hold yet: writes the
# comments a batch carries for one object that the replica does not hold, a
# reply only once the comment it answers is held, as schema_comments does.
def batch_comments(crm_id, object_id, comments, now):
	pending = []
	for c in sequence(comments):
		if not sync_element(c, ["id"]) or not identifier(c["id"]):
			continue
		# Skip a comment id already owned by another CRM's object, or held
		# by an object.
		if foreign_comment(c["id"], crm_id):
			continue
		if not mochi.db.exists("select 1 from comments where id=?", c["id"]):
			pending.append(c)
	for _ in range(len(pending)):
		if not pending:
			break
		waiting = []
		for c in pending:
			parent = text(c.get("parent"))
			place = comment_parent_check(c["id"], object_id, parent)
			if place == "late":
				waiting.append(c)
			elif place == "ok":
				row_merge("comments", ["id"], {"id": c["id"], "object": object_id, "parent": parent, "author": text(c.get("author")), "name": text(c.get("name")), "content": text(c.get("content")), "created": number(c.get("created"), now), "edited": number(c.get("edited"))})
		if len(waiting) == len(pending):
			break
		pending = waiting
	return len(pending) > 0

def event_sync_batch(e):
	# Sync is sent from the CRM entity (p2p_headers(crm_id, ...)), so the
	# authenticated sender is the CRM. Trust the from header, not a spoofable
	# content field, so a peer can't inject forged data into a subscribed CRM.
	crm_id = e.header("from")
	if not crm_id:
		return
	crm = mochi.db.row("select id from crms where id=? and owner=0", crm_id)
	if not crm:
		unsubscribe_stale(e)
		return
	# A sync batch writes to the replica as a live event does (verify_subscription).
	schema_cancel(crm_id)
	now = mochi.time.now()

	# Process classes. Every field of every row is reduced to the type its
	# column holds (class_row, field_row, option_row, view_row).
	for t in sequence(e.content("classes")):
		if not sync_element(t, ["id", "name"]):
			continue
		row = class_row(crm_id, t)
		if not row:
			continue
		if "title" not in t:
			row["title"] = "title"
		row_merge("classes", ["crm", "id"], row)
		# Hierarchy, added here; the parents it no longer names go once the
		# sync is complete (batch_design_reconcile).
		for p in sequence(t.get("parents")):
			if type(p) != "string":
				continue
			row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": row["id"], "parent": p})
		# Fields
		for f in sequence(t.get("fields")):
			if not sync_element(f, ["id", "name", "fieldtype"]):
				continue
			field = field_row(crm_id, row["id"], f)
			if not field:
				continue
			field_merge(field)
			# Options
			for o in sequence(f.get("options")):
				if not sync_element(o, ["id", "name"]):
					continue
				option = option_row(crm_id, row["id"], field["id"], o)
				if option:
					row_merge("options", ["crm", "class", "field", "id"], option)

	# Process views
	for v in sequence(e.content("views")):
		if not sync_element(v, ["id", "name", "viewtype"]):
			continue
		row = view_row(crm_id, v)
		if not row:
			continue
		row_merge("views", ["crm", "id"], row)
		# View fields and classes, added here; the ones a view no longer names
		# go once the sync is complete (batch_design_reconcile).
		for i, field_id in enumerate(text(v.get("fields")).split(",")):
			if field_id:
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": row["id"], "field": field_id, "rank": i})
		# A class the replica does not hold would fail the row's foreign key.
		for class_id in text(v.get("classes")).split(","):
			if class_id and schema_class(crm_id, class_id):
				row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": row["id"], "class": class_id})
	# Process objects
	late = False
	for obj in sequence(e.content("objects")):
		if not sync_element(obj, ["id"]) or not identifier(obj["id"]):
			continue
		# Never adopt/reassign an object that already belongs to another CRM, or
		# an id a comment holds - a hijacking owner's batch could otherwise
		# write values, comments and activity onto our other CRMs' rows via a
		# colliding id (mirrors insert_schema's foreign_object guard).
		if foreign_object(obj["id"], crm_id):
			continue
		# The object's version (version_take): a copy of an object the batch
		# carries at a later version takes its row, and its values only while
		# no later change has reached it first. From an owner that predates
		# versions, an object held already keeps its row.
		version = owner_version(obj.get("version"))
		row = {"id": obj["id"], "crm": crm_id, "class": text(obj.get("class")), "parent": text(obj.get("parent")), "rank": rank_copy(obj.get("rank")), "created": number(obj.get("created"), now), "updated": number(obj.get("updated"), now), "version": version or 0}
		if not mochi.db.exists("select 1 from objects where id=?", obj["id"]):
			# A class the replica does not hold would fail the row's foreign
			# key and abort the batch; the pull below brings both.
			if not schema_class(crm_id, row["class"]):
				late = True
				continue
			row_merge("objects", ["id"], row)
		elif version != None and schema_class(crm_id, row["class"]):
			row_set("objects", "id=? and crm=? and version<?", [obj["id"], crm_id, version], {k: row[k] for k in row if k not in ["id", "crm"]})
		# Values, each through the one replica value writer (value_write).
		values = record(obj.get("values"))
		if values and (version == None or mochi.db.exists("select 1 from objects where id=? and crm=? and version<=?", obj["id"], crm_id, version)):
			for field, value in values.items():
				value_write(crm_id, obj["id"], field, value)
		# Comments, a reply only under a comment of the same object.
		if batch_comments(crm_id, obj["id"], obj.get("comments"), now):
			late = True
		# Activity history
		for act in sequence(obj.get("activity")):
			if not sync_element(act, ["id"]) or not identifier(act["id"]):
				continue
			if not mochi.db.exists("select 1 from objects where id=? and crm=?", obj["id"], crm_id):
				continue
			mochi.db.execute(
				"insert or ignore into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
				act["id"], obj["id"], text(act.get("user")), text(act.get("action")),
				text(act.get("field")), text(act.get("oldvalue")), text(act.get("newvalue")),
				number(act.get("created"), now)
			)

	# Process links
	for l in sequence(e.content("links")):
		if not sync_element(l, ["source", "target"]):
			continue
		if not link_endpoints_bound(crm_id, text(l["source"]), text(l["target"])):
			continue
		row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": l["source"], "target": l["target"], "linktype": link_type(l.get("linktype")), "created": number(l.get("created"))})

	# The roster, and which member owns the CRM.
	if e.content("owner"):
		member_owner(crm_id, e.content("owner"))
	for m in sequence(e.content("members")):
		m = record(m)
		member_store(crm_id, m.get("id"), m.get("name"))

	# Once every chunk of the sync has landed, whatever order they arrived in:
	# drop the parents, view fields and view classes the batch no longer names,
	# and mark the subscription's initial bulk content as arrived so the board
	# stops showing its loading state. A counted sync carries the design in
	# every chunk, and reconciling on each let a chunk delivered after a design
	# change take that change away again. An owner before counting sends the
	# design in its first chunk only, so that chunk is reconciled as it lands.
	chunk = e.content("chunk")
	complete = batch_complete(crm_id, chunk)
	if complete or type(chunk) != "dict" or chunk.get("total") == None:
		batch_design_reconcile(crm_id, e)
	if complete:
		row_set("crms", "id=? and owner=0", [crm_id], {"populated": 1})
	# Notify UI
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/update", "crm": crm_id})
	# A reply whose comment this batch did not bring, or an object whose class
	# it did not, from a chunk not yet landed or a change since: the replica
	# pulls what it lacks.
	if late:
		request_resync(crm_id)

# Tell the owner to drop this member when a broadcast arrives for a CRM not held
# locally. Subscribe writes the local row before notifying the owner, so a
# missing row here is always a stale roster entry, never an in-flight subscribe.
# Broadcast headers invert: from=crm, to=member. A CRM this user owns is never
# stale: a message from it to one of this user's own identities (core delivers
# those, broadcast or not) would otherwise unsubscribe the owner from their own
# CRM.
def unsubscribe_stale(e):
	crm_id = e.header("from")
	member_id = e.header("to")
	if not crm_id or not member_id:
		return
	if mochi.db.exists("select 1 from crms where id=? and owner=1", crm_id):
		return
	mochi.message.send(p2p_headers(member_id, crm_id, "unsubscribe"), {})

def verify_subscription(e):
	# Broadcasts are sent from the CRM entity itself (broadcast_event uses
	# from=crm_id), so the authenticated P2P sender IS the CRM. Trust the from
	# header rather than a spoofable content field, so a peer can't push forged
	# state into a CRM we subscribe to.
	crm_id = e.header("from")
	if not crm_id:
		return None
	crm = mochi.db.row("select id from crms where id=? and owner=0", crm_id)
	if not crm:
		unsubscribe_stale(e)
		return None
	# Every live event that writes to a replica comes through here, so here a
	# pull under way stops pruning: it could prune what the event writes.
	schema_cancel(crm_id)
	return crm_id

# CRM updated
def event_crm_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	name = e.content("name")
	description = e.content("description")
	if name != None:
		row_set("crms", "id=?", [crm_id], {"name": name})
	if description != None:
		row_set("crms", "id=?", [crm_id], {"description": description})
	row_set("crms", "id=?", [crm_id], {"updated": mochi.time.now()})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/update", "crm": crm_id})

# The owner replaced the design wholesale (a design import, or a data import
# that applied one): pull the CRM afresh at once, a pull that prunes, so what
# the old design held and the new one dropped leaves the copy too.
def event_design_replace(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	request_resync(crm_id, False, None, True)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/update", "crm": crm_id})

# A member joined the CRM, or changed the name they go by: the copy's roster
# (subscribers) names them, so the people list, the owner's name and their
# avatar read as they do on the owner.
def event_member_add(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	if not member_store(crm_id, e.content("id"), e.content("name")):
		return
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/update", "crm": crm_id})

# A member left the CRM, or lost access to it.
def event_member_remove(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	id = e.content("id")
	if type(id) != "string" or not id:
		return
	row_remove("subscribers", "crm=? and id=?", [crm_id, id])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/update", "crm": crm_id})

# Object created
def event_object_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	object_id = e.content("id")
	if not identifier(object_id):
		return
	# A colliding global id that already belongs to another CRM, or to a
	# comment, is a hijack attempt by the sending owner - never let its payload
	# (values, watcher, notification) touch that row. Mirrors insert_schema's
	# foreign_object guard.
	if foreign_object(object_id, crm_id):
		return
	class_id = text(e.content("class"))
	# Skip when the class isn't local yet — objects(crm,class) FK would
	# otherwise abort the handler. Resync pulls the canonical schema so
	# future events apply cleanly.
	if not class_id or not mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id):
		request_resync(crm_id)
		return
	version = owner_version(e.content("version"))
	if not mochi.db.exists("select 1 from objects where id=?", object_id):
		row_merge("objects", ["id"], {"id": object_id, "crm": crm_id, "class": class_id, "parent": text(e.content("parent")), "rank": rank_copy(e.content("rank")), "created": number(e.content("created")) or mochi.time.now(), "updated": number(e.content("updated")) or mochi.time.now(), "version": version or 0})
	# Store field values included in the broadcast, not over a later change of
	# the object that landed first, each through the one replica value writer.
	values = record(e.content("values"))
	if values and mochi.db.exists("select 1 from objects where id=? and crm=? and version<=?", object_id, crm_id, version or 0):
		for field, value in values.items():
			value_write(crm_id, object_id, field, value)
	user = e.content("user") or ""
	# Activity history arrives separately via the activity/log broadcast,
	# so we don't insert a local row here (it would have a different UID
	# from the owner's authoritative row).
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "object/create", "crm": crm_id, "id": object_id})
	# Auto-watch creator locally (safety net for when forward_to_owner response is lost)
	local_id = e.header("to")
	if user and user == local_id:
		row_merge("watchers", ["object", "user"], {"object": object_id, "user": local_id, "created": number(e.content("created")) or mochi.time.now()})
	# Notify local user about new object
	if local_id and local_id != user:
		crm = get_crm(crm_id)
		if crm:
			obj = mochi.db.row("select class from objects where id=?", object_id)
			if obj:
				title = get_object_display(crm, obj, object_id)
				fp2 = mochi.entity.fingerprint(crm_id)
				url = "/crm/" + fp2 + "/" + object_id if fp2 else "/crm"
				notify("update/created", crm_id, title, mochi.app.label("notifications.body.created"), url, event_id="update/created:" + object_id)

# Object updated
def event_object_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	object_id = e.content("id")
	if not object_id:
		return

	# Skip when the object isn't local yet — the UPDATE would silently
	# no-op, leaving us with stale or missing rows until something else
	# triggers a sync.
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		request_resync(crm_id)
		return

	# The owner's version of the object for the change (version_take): one no
	# newer than this copy's, which a later change or a pull has reached, is
	# dropped. The events of one change carry one version, so a copy at it takes
	# them all. From an owner that predates versions, events are ordered by the
	# owner's time instead, an update no newer than the copy's dropped. Senders
	# without the time fall back to local now.
	now = mochi.time.now()
	version = owner_version(e.content("version"))
	incoming = str(e.content("updated", "0"))
	if mochi.text.valid(incoming, "integer"):
		incoming = int(incoming)
	else:
		incoming = 0
	local = mochi.db.row("select updated, version from objects where id=? and crm=?", object_id, crm_id)
	if version != None:
		if local and (local["version"] or 0) > version:
			return
	elif incoming:
		if local and local["updated"] and incoming <= local["updated"]:
			return

	# A class not held here yet, from a class event that has not landed, would
	# fail the write's foreign key and lose the update; the resync brings both.
	class_id = e.content("class")
	if class_id and not mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id):
		request_resync(crm_id)
		return
	# No rank: an owner sends a move's keys in object/ranks, which checks each,
	# and no owner since that event's introduction has sent one here.
	parent = e.content("parent")
	updates = {"updated": incoming if incoming else now}
	if class_id:
		updates["class"] = class_id
	if parent != None:
		updates["parent"] = parent
	# The version checked again in the same statement, so an answer landing
	# since the read is not undone.
	if version != None:
		updates["version"] = version
		row_set("objects", "id=? and crm=? and version<=?", [object_id, crm_id, version], updates)
	else:
		row_set("objects", "id=? and crm=?", [object_id, crm_id], updates)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "object/update", "crm": crm_id, "id": object_id})
	# Notify local user if watching
	if not e.content("sync"):
		user = e.content("user") or ""
		local_id = e.header("to")
		if local_id:
			notify_watchers(object_id, crm_id, local_id, user, mochi.app.label("notifications.body.updated"))

# owner_time(value) -> int or None: an owner's updated time as an event or an
# answer carries it, an integer or its string; None for anything else.
def owner_time(value):
	value = str(value) if value != None else ""
	return int(value) if mochi.text.valid(value, "integer") else None

# owner_version(value) -> int or None: an object's version as an owner's event
# or answer carries it (version_take), an integer or its string; None from an
# owner that predates versions, whose changes are ordered by its time instead.
def owner_version(value):
	return owner_time(value)

# ranks_apply(crm_id, ranks, time=None, answer=False, handle=None) -> (whether
# any, whether one names an object this copy lacks): write the owner's keys, a
# list of {id, rank, version}, to the CRM's objects they name, with the owner's
# updated time on the one the move changed. An object the owner only re-keyed
# keeps its time. A key no owner mints, one not canonical or past RANK_LENGTH,
# is skipped, as object_replicate takes only a canonical one. An entry with
# its object's version is skipped when the copy's version is past it: an
# answer can land after the broadcast of a later change, a re-key included,
# and would put it back. With answer, the entries of the owner's answer to a
# forwarded move, the version is kept only when it is the next after the
# copy's (answer_claim). An entry from an owner that predates versions is
# skipped when the copy's time for its object is later than the owner's for
# the key, the entry's own or the move's (time).
# The caller pulls the CRM for an object this copy does not hold, as
# values/update does. Within a transaction (handle) every read and write goes
# through it.
def ranks_apply(crm_id, ranks, time=None, answer=False, handle=None):
	database = handle or mochi.db
	if type(ranks) not in ("list", "tuple") or not ranks:
		return False, False
	missing = False
	for r in ranks:
		if type(r) != "dict":
			continue
		obj_id = r.get("id")
		rank = r.get("rank")
		if type(obj_id) != "string" or not obj_id or not rank_valid(rank):
			continue
		local = database.row("select updated, version from objects where id=? and crm=?", obj_id, crm_id)
		if not local:
			missing = True
			continue
		updated = owner_time(r.get("updated"))
		version = owner_version(r.get("version"))
		changes = {"rank": rank}
		if updated:
			changes["updated"] = updated
		if version != None:
			held = local["version"] or 0
			if held > version:
				continue
			if not answer or held >= version - 1:
				changes["version"] = version
			row_set("objects", "id=? and crm=? and version=?", [obj_id, crm_id, held], changes, handle)
			continue
		since = updated or time
		if since and (local["updated"] or 0) > since:
			continue
		row_set("objects", "id=? and crm=?", [obj_id, crm_id], changes, handle)
	return True, missing

# The keys a move wrote, applied under the same subscription check and websocket
# notice as object/update, each unless this copy holds a later change of its
# object (ranks_apply).
def event_object_ranks(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	applied, missing = ranks_apply(crm_id, e.content("ranks"), owner_time(e.content("updated")))
	if missing:
		request_resync(crm_id)
	if not applied:
		return
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "object/ranks", "crm": crm_id})

# Object deleted
def event_object_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	object_id = e.content("id")
	if not object_id:
		return
	# The object must belong to this CRM before we cascade-delete its children;
	# otherwise a subscribed CRM's owner could wipe another CRM's watchers/
	# activity/comments/values/links by naming a foreign object id.
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		return
	# Notify local user before deleting watchers
	user = e.content("user") or ""
	local_id = e.header("to")
	if local_id:
		notify_watchers(object_id, crm_id, local_id, user, mochi.app.label("notifications.body.deleted"))
	delete_object_local(crm_id, object_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "object/delete", "crm": crm_id, "id": object_id})

# Values updated
def event_values_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	object_id = e.content("id")
	if type(object_id) != "string" or not object_id:
		return
	values = record(e.content("values"))
	if not values:
		return
	# Skip when the referenced object isn't local yet. The values.object FK
	# would otherwise abort the handler and the update would be lost
	# forever (the owner has no idea we couldn't apply it). request_resync
	# pulls the canonical schema so we converge on the next event.
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		request_resync(crm_id)
		return
	# The owner's time for the change, as object/update and object/ranks carry
	# it: this server's own would run ahead of the owner's after a change that
	# wrote no key. An owner that predates sending it leaves the copy's time as
	# it was. With the object's version, the values are written only when the
	# copy's is not past it (event_object_update), the version kept with them in
	# one transaction, so an answer landing beside them does not interleave.
	updated = owner_time(e.content("updated"))
	version = owner_version(e.content("version"))
	handle = mochi.db.transaction() if version != None else None
	if handle:
		changes = {"version": version}
		if updated:
			changes["updated"] = updated
		row_set("objects", "id=? and crm=? and version<=?", [object_id, crm_id, version], changes, handle)
		if not handle.exists("select 1 from objects where id=? and crm=? and version=?", object_id, crm_id, version):
			handle.rollback()
			return
	for field in values:
		value_write(crm_id, object_id, field, values[field], handle)
	if handle:
		handle.commit()
	elif updated:
		row_set("objects", "id=? and crm=?", [object_id, crm_id], {"updated": updated})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "values/update", "crm": crm_id, "id": object_id})
	# Notify local user if watching
	if not e.content("sync"):
		user = e.content("user") or ""
		local_id = e.header("to")
		if local_id:
			# Check for assignment notification first
			assigned = False
			obj_row = mochi.db.row("select class from objects where id=? and crm=?", object_id, crm_id)
			if obj_row:
				for field in values:
					if str(values[field]) == local_id:
						field_row = mochi.db.row(
							"select fieldtype from fields where crm=? and class=? and id=?",
							crm_id, obj_row["class"], field)
						if field_row and field_row["fieldtype"] == "user":
							assigned = True
							crm = get_crm(crm_id)
							if crm:
								obj = mochi.db.row("select class from objects where id=?", object_id)
								if obj:
									title = get_object_display(crm, obj, object_id)
									fp2 = mochi.entity.fingerprint(crm_id)
									url = "/crm/" + fp2 + "/" + object_id if fp2 else "/crm"
									notify("assignment", crm_id, title, mochi.app.label("notifications.body.assigned_to_you"), url, event_id="assignment:" + object_id + ":" + local_id)
							# Auto-watch on assignment
							row_merge("watchers", ["object", "user"], {"object": object_id, "user": local_id, "created": mochi.time.now()})
			if not assigned:
				notify_watchers(object_id, crm_id, local_id, user, mochi.app.label("notifications.body.updated"))

# Activity row replicated from owner — insert with the same UID so the
# activity table converges across hosts. If the referenced object isn't
# local yet (out-of-order delivery) we resync; the fresh schema pulls in
# both the missing object and its activity history together.
def event_activity_log(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	activity_id = e.content("id")
	object_id = e.content("object")
	if not identifier(activity_id) or type(object_id) != "string" or not object_id:
		return
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		request_resync(crm_id)
		return
	created = e.content("created")
	if not mochi.text.valid(str(created), "integer"):
		created = mochi.time.now()
	else:
		created = int(created)
	# Each column is reduced to its type before it is bound: a list is spread
	# over the placeholders after it, misaligning the row's own columns.
	mochi.db.execute(
		"insert or ignore into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
		activity_id, object_id, text(e.content("user")),
		text(e.content("action")), text(e.content("field")),
		text(e.content("oldvalue")), text(e.content("newvalue")),
		created
	)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "activity/log", "crm": crm_id, "object": object_id})

# Comment submitted by remote subscriber (fire-and-forget)
def event_comment_submit(e):
	crm_id = e.header("to")
	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		return
	sender = e.header("from")
	if not check_crm_access(sender, crm_id, "comment"):
		return
	comment_id = e.content("id")
	object_id = e.content("object")
	# The submitter minted the id with mochi.uid on its host; anything else is
	# a hand-built frame, and the id becomes a primary key and a URL segment.
	if not identifier(comment_id) or not object_id:
		return
	if not mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id):
		return
	parent = e.content("parent") or ""
	content = e.content("content") or ""
	name = e.content("name") or ""
	if type(parent) != "string" or type(content) != "string" or type(name) != "string":
		return
	if not content.strip():
		return
	# Both sibling entry points cap these; this one had no ceiling but core's
	# 16 MB frame, and the owner re-broadcasts whatever lands here.
	if check_length(content, 50000):
		return
	if check_length(name, 255):
		return
	# The name is rendered everywhere the comment is: a bidi override or a
	# control character in it would reach every replica's UI.
	if name and not mochi.text.valid(name, "display"):
		name = ""
	# The HTTP owner path checks the parent against the object; without it a
	# subscriber can parent a comment onto another object's thread, where
	# object_comments never walks and nothing ever renders it.
	if parent and not mochi.db.exists("select 1 from comments where id=? and object=?", parent, object_id):
		return
	# The id is the sender's choice, so it must be one no row holds: an object's
	# or another comment's, in any CRM, would make this comment that row and its
	# attachments this comment's. The one row it may name is this sender's own
	# comment on this object: a redelivery after a failure past the insert,
	# which carries on with what follows rather than leave the comment
	# unannounced.
	now = mochi.time.now()
	landed = mochi.db.row("select object, author from comments where id=?", comment_id)
	if landed:
		if landed["object"] != object_id or landed["author"] != sender:
			return
	elif identifier_held(comment_id):
		return
	else:
		row_merge("comments", ["id"], {"id": comment_id, "object": object_id, "parent": parent, "author": sender, "name": name, "content": content.strip(), "created": now, "edited": 0})
	# Store the submission's attachment metadata and take the bytes in from
	# the sender now, while it is online; a pull that fails heals on serve.
	attachments = e.content("attachments") or []
	if attachments:
		attachment_accept(attachments, sender, comment_id, crm_id, kind="comment")
	row_set("objects", "id=?", [object_id], {"updated": now})
	log_activity(object_id, sender, "commented")
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": sender, "created": now})
	# Send WebSocket notification to owner for real-time UI updates
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "comment/create", "crm": crm_id, "object": object_id})
	# Broadcast to all subscribers with attachment metadata
	comment_event = {
		"crm": crm_id, "object": object_id, "id": comment_id,
		"parent": parent, "author": sender, "name": name,
		"content": content.strip(), "created": now, "user": sender
	}
	if attachments:
		comment_event["attachments"] = attachments
	broadcast_event(crm_id, "comment/create", comment_event, exclude=sender)
	# Notify watchers
	owner_id = get_owner_identity(crm_id)
	excerpt = content.strip()[:80]
	notify_watchers(object_id, crm_id, owner_id, sender, mochi.app.label("notifications.body.commented", name=name, excerpt=excerpt))
	# A subscriber's comment can name someone too. Without this, being
	# mentioned only notified you when the CRM's owner typed it.
	notify_mentions(object_id, crm_id, content, sender, name)

# Attachment submitted by subscriber
def event_attachment_submit(e):
	crm_id = e.header("to")
	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		return
	sender = e.header("from")
	if not check_crm_access(sender, crm_id, "write"):
		return
	object_id = e.content("object")
	if not object_id:
		return
	if not mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id):
		return
	now = mochi.time.now()
	row_set("objects", "id=?", [object_id], {"updated": now})
	names = e.content("names") or []
	for name in names:
		log_activity(object_id, sender, "attached", "", "", name)
	# Store the legacy metadata-only submission (subscribers not yet on the
	# push flow) and take the bytes in from the sender while it is online.
	attachments = e.content("attachments") or []
	if attachments:
		attachment_accept(attachments, sender, object_id, crm_id)
	# Broadcast to other subscribers with attachment metadata
	if attachments:
		broadcast_event(crm_id, "attachment/add", {
			"crm": crm_id, "object": object_id,
			"attachments": attachments
		}, exclude=sender)
	# Send WebSocket notification to owner for real-time UI updates
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "attachment/create", "crm": crm_id, "object": object_id})

# Attachment metadata received from owner
def event_attachment_add(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	object_id = e.content("object")
	attachments = e.content("attachments") or []
	# Only attach to an object that belongs to this crm.
	if attachments and object_id and mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		attachment_store(attachments, e.header("from"), object_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "attachment/create", "crm": crm_id, "object": object_id})

# Attachment removed by owner
def event_attachment_remove(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	attachment_id = e.content("attachment")
	# Bind the attachment to an object/comment in this crm before deleting
	# (mirrors serve_attachment) so a colliding id can't reach another crm's.
	if attachment_id and attachment_in_crm(attachment_id, crm_id):
		attachment_delete(attachment_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "attachment/delete", "crm": crm_id, "attachment": attachment_id})

# Comment created
def event_comment_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	comment_id = e.content("id")
	object_id = e.content("object") or ""
	# The owner chose the id: one not in the shape mochi.uid() mints, one an
	# object holds, or one of another CRM's comments is refused.
	if not identifier(comment_id) or foreign_comment(comment_id, crm_id):
		return
	# Skip when the comment's object isn't local yet — comments.object FK
	# would otherwise abort the handler and the comment would be lost.
	if type(object_id) != "string" or not object_id or not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		request_resync(crm_id)
		return
	if not mochi.db.exists("select 1 from comments where id=?", comment_id):
		# A reply hangs only under another comment of the same object, and
		# never closes a loop of replies; one under a comment not held yet came
		# out of order, and the pull brings both.
		parent = text(e.content("parent"))
		place = comment_parent_check(comment_id, object_id, parent)
		if place == "late":
			request_resync(crm_id)
			return
		if place != "ok":
			return
		row_merge("comments", ["id"], {"id": comment_id, "object": object_id, "parent": parent, "author": text(e.content("author")), "name": text(e.content("name")), "content": text(e.content("content")), "created": number(e.content("created")) or mochi.time.now(), "edited": 0})
	# The object was checked against this CRM; the id was not. Without this the
	# owner of a CRM we subscribe to names a comment in a different CRM, and its
	# attachments then resolve to bytes held by that owner.
	if not comment_bound(comment_id, object_id):
		return
	# Store attachment metadata from the event
	attachments = e.content("attachments") or []
	if attachments:
		attachment_store(attachments, e.header("from"), comment_id, kind="comment")
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "comment/create", "crm": crm_id, "object": e.content("object")})
	# Auto-watch commenter and notify local user if watching
	if not e.content("sync"):
		user = e.content("user") or ""
		local_id = e.header("to")
		object_id = e.content("object")
		if object_id and local_id:
			# Auto-watch commenter locally (safety net for when forward_to_owner response is lost)
			if user and user == local_id:
				row_merge("watchers", ["object", "user"], {"object": object_id, "user": local_id, "created": number(e.content("created")) or mochi.time.now()})
			name = text(e.content("name")) or mochi.app.label("notifications.mention.author_unknown")
			excerpt = text(e.content("content"))[:80]
			notify_watchers(object_id, crm_id, local_id, user, mochi.app.label("notifications.body.commented", name=name, excerpt=excerpt))

# Comment updated
# The object a comment belongs to, so a comment push can name it - the
# detail sheet filters pushes on the object it shows.
def comment_object(comment_id):
	row = mochi.db.row("select object from comments where id=?", comment_id)
	return row["object"] if row else ""

def event_comment_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	comment_id = e.content("id")
	if not comment_id:
		return
	# Skip unless the comment's object belongs to THIS crm — without the object
	# join a subscribed crm's owner could overwrite any comment in any crm by id.
	# (Also skips when not local yet; request_resync fills it in.)
	if not mochi.db.exists("select 1 from comments c join objects o on c.object=o.id where c.id=? and o.crm=?", comment_id, crm_id):
		request_resync(crm_id)
		return
	content = e.content("content")
	if content:
		row_set("comments", "id=?", [comment_id], {"content": content, "edited": mochi.time.now()})
	object_id = comment_object(comment_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "comment/update", "crm": crm_id, "object": object_id, "id": comment_id})

# Comment deleted
def event_comment_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	comment_id = e.content("id")
	if not comment_id:
		return
	object_id = comment_object(comment_id)
	delete_comment_tree(comment_id, crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "comment/delete", "crm": crm_id, "object": object_id, "id": comment_id})

# Link created
def event_link_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	source = text(e.content("source"))
	target = text(e.content("target"))
	# Skip when either endpoint isn't local yet — links FKs would abort.
	if not source or not target:
		return
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", source, crm_id) or \
		not mochi.db.exists("select 1 from objects where id=? and crm=?", target, crm_id):
		request_resync(crm_id)
		return
	row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": source, "target": target, "linktype": link_type(e.content("linktype")), "created": number(e.content("created")) or mochi.time.now()})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "link/create", "crm": crm_id})
	# Notify local user if watching
	if not e.content("sync"):
		user = e.content("user") or ""
		local_id = e.header("to")
		source = e.content("source")
		if source and local_id:
			notify_watchers(source, crm_id, local_id, user, mochi.app.label("notifications.body.link_added"))

# Link deleted
def event_link_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	row_remove("links", "crm=? and source=? and target=? and linktype=?", [crm_id, e.content("source") or "", e.content("target") or "", link_type(e.content("linktype"))])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "link/delete", "crm": crm_id})

# View created
def event_view_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	# Each field reduced to the type its column holds (view_row), so a value of
	# another type skips it rather than aborting the handler.
	row = view_row(crm_id, {key: e.content(key) for key in ["id", "name", "viewtype", "filter", "columns", "rows", "sort", "direction", "rank", "border"]})
	if not row:
		return
	view_id = row["id"]
	row_merge("views", ["crm", "id"], row)
	# Sync view fields
	rank = 0
	for field_id in text(e.content("fields")).split(","):
		if field_id:
			row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field_id, "rank": rank})
			rank += 1
	# Sync view classes, each a class the copy holds: view_classes carries a
	# foreign key to it, and a class not held yet comes with a pull.
	missing = False
	for class_id in text(e.content("classes")).split(","):
		if not class_id:
			continue
		if not schema_class(crm_id, class_id):
			missing = True
			continue
		row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": class_id})
	if missing:
		request_resync(crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "view/create", "crm": crm_id, "id": view_id})

# View updated
def event_view_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	view_id = e.content("id")
	if not view_id:
		return
	name = e.content("name")
	viewtype = e.content("viewtype")
	filter_val = e.content("filter")
	columns = e.content("columns")
	rows = e.content("rows")
	sort = e.content("sort")
	direction = e.content("direction")
	if name:
		row_set("views", "id=? and crm=?", [view_id, crm_id], {"name": name})
	if viewtype:
		row_set("views", "id=? and crm=?", [view_id, crm_id], {"viewtype": viewtype})
	if filter_val != None:
		row_set("views", "id=? and crm=?", [view_id, crm_id], {"filter": filter_val})
	if columns != None:
		row_set("views", "id=? and crm=?", [view_id, crm_id], {"columns": columns})
	if rows != None:
		row_set("views", "id=? and crm=?", [view_id, crm_id], {"rows": rows})
	if sort != None:
		row_set("views", "id=? and crm=?", [view_id, crm_id], {"sort": sort})
	if direction != None:
		row_set("views", "id=? and crm=?", [view_id, crm_id], {"direction": direction})
	border = e.content("border")
	if border != None:
		row_set("views", "id=? and crm=?", [view_id, crm_id], {"border": border})
	# Sync view fields if provided: comma-joined text, so a value of another
	# type is left as it was rather than split.
	fields_csv = text(e.content("fields"), None)
	if fields_csv != None:
		row_remove("view_fields", "crm=? and view=?", [crm_id, view_id])
		rank = 0
		for field_id in fields_csv.split(","):
			if field_id:
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field_id, "rank": rank})
				rank += 1
	# Sync view classes if provided, each a class the copy holds; a class not
	# held yet comes with a pull.
	classes_csv = text(e.content("classes"), None)
	if classes_csv != None:
		row_remove("view_classes", "crm=? and view=?", [crm_id, view_id])
		missing = False
		for class_id in classes_csv.split(","):
			if not class_id:
				continue
			if not schema_class(crm_id, class_id):
				missing = True
				continue
			row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": class_id})
		if missing:
			request_resync(crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "view/update", "crm": crm_id, "id": view_id})

# View deleted
def event_view_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	view_id = e.content("id")
	if not view_id:
		return
	row_remove("views", "id=? and crm=?", [view_id, crm_id])
	row_remove("view_fields", "view=? and crm=?", [view_id, crm_id])
	row_remove("view_classes", "view=? and crm=?", [view_id, crm_id])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "view/delete", "crm": crm_id, "id": view_id})

# Type created
def event_class_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	row = class_row(crm_id, {key: e.content(key) for key in ["id", "name", "rank", "title"]})
	if not row:
		return
	row_merge("classes", ["crm", "id"], row)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "class/create", "crm": crm_id, "id": row["id"]})

# Type updated
def event_class_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("id")
	if not class_id:
		return
	name = e.content("name")
	if name != None:
		row_set("classes", "id=? and crm=?", [class_id, crm_id], {"name": name})
	title = e.content("title")
	if title != None:
		row_set("classes", "id=? and crm=?", [class_id, crm_id], {"title": title})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "class/update", "crm": crm_id, "id": class_id})

# Class deleted
def event_class_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("id")
	if not class_id:
		return
	row_remove("options", "crm=? and class=?", [crm_id, class_id])
	row_remove("fields", "crm=? and class=?", [crm_id, class_id])
	row_remove("view_classes", "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", "crm=? and parent=?", [crm_id, class_id])
	row_remove("classes", "id=? and crm=?", [class_id, crm_id])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "class/delete", "crm": crm_id, "id": class_id})

# Hierarchy set
def event_hierarchy_set(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	if not class_id:
		return
	# The rules hang off a class the copy holds (their foreign key); one not
	# held yet comes with a pull.
	if not schema_class(crm_id, class_id):
		request_resync(crm_id)
		return
	# The parents a list; anything else is the wrong shape, and the class keeps
	# its rules until a resync rather than losing them all.
	parents = e.content("parents")
	if parents != None and type(parents) not in ("list", "tuple"):
		request_resync(crm_id)
		return
	# Clear existing hierarchy for this class
	row_remove("hierarchy", "crm=? and class=?", [crm_id, class_id])
	# Insert new parents: the top level (""), or a class the copy holds, as the
	# owner stores them. A parent class the copy does not hold yet comes with a
	# pull.
	missing = False
	for parent in sequence(parents):
		if type(parent) != "string":
			continue
		if parent and not schema_class(crm_id, parent):
			missing = True
			continue
		row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": class_id, "parent": parent})
	if missing:
		request_resync(crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "hierarchy/set", "crm": crm_id, "class": class_id})

# Field created
def event_field_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	# The field's class must be held (the row's foreign key); one not held yet
	# comes with a pull. A field created as a user field keeps only values that
	# are entity ids (field_merge).
	class_id = text(e.content("class"))
	row = field_row(crm_id, class_id, {key: e.content(key) for key in FIELD_COLUMNS if key != "class"})
	if not row:
		return
	if not schema_class(crm_id, class_id):
		request_resync(crm_id)
		return
	field_merge(row)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "field/create", "crm": crm_id, "class": class_id, "id": row["id"]})

# Field updated
def event_field_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	field_id = e.content("id")
	if type(class_id) != "string" or not class_id or type(field_id) != "string" or not field_id:
		return
	# Handle field ID rename: from a field the copy holds, to an id it does
	# not, as the owner's own rename requires; anything else would fail the
	# rename's key part-way or merge two fields.
	previous = e.content("previous")
	if type(previous) == "string" and not mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, field_id):
		rename_field_id(crm_id, class_id, previous, field_id)
	# The rename has already happened, so attribute changes address the new id.
	current_id = field_id
	name = e.content("name")
	flags = e.content("flags")
	multi = e.content("multi")
	card = e.content("card")
	min_val = e.content("min")
	max_val = e.content("max")
	pattern = e.content("pattern")
	minlength = e.content("minlength")
	maxlength = e.content("maxlength")
	prefix = e.content("prefix")
	suffix = e.content("suffix")
	format_str = e.content("format")
	position = e.content("position")
	rows_val = e.content("rows")
	if name != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"name": name})
	if flags != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"flags": flags})
	if multi != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"multi": multi})
	if card != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"card": card})
	if min_val != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"min": min_val})
	if max_val != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"max": max_val})
	if pattern != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"pattern": pattern})
	if minlength != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"minlength": minlength})
	if maxlength != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"maxlength": maxlength})
	if prefix != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"prefix": prefix})
	if suffix != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"suffix": suffix})
	if format_str != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"format": format_str})
	if position != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"position": position})
	if rows_val != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"rows": rows_val})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "field/update", "crm": crm_id, "class": class_id, "id": field_id})

# Field deleted
def event_field_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	field_id = e.content("id")
	if not class_id or not field_id:
		return
	field_remove(crm_id, class_id, field_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "field/delete", "crm": crm_id, "class": class_id, "id": field_id})

# View reorder
def event_view_reorder(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	# A list of ids: anything else reorders nothing (sequence), and an entry
	# that is not an id is one row_set refuses.
	order = sequence(e.content("order"))
	if not order:
		return
	for i, view_id in enumerate(order):
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"rank": i})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "view/reorder", "crm": crm_id})

def event_field_reorder(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	# A list of ids: anything else reorders nothing (sequence), and an entry
	# that is not an id is one row_set refuses.
	order = sequence(e.content("order"))
	if not class_id or not order:
		return
	for i, field_id in enumerate(order):
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rank": i})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "field/reorder", "crm": crm_id, "class": class_id})

# Option created
def event_option_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	# The option's field must be held (the row's foreign key); one not held
	# yet comes with a pull.
	row = option_row(crm_id, text(e.content("class")), text(e.content("field")), {key: e.content(key) for key in ["id", "name", "colour", "icon", "rank"]})
	if not row:
		return
	if not mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, row["class"], row["field"]):
		request_resync(crm_id)
		return
	row_merge("options", ["crm", "class", "field", "id"], row)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "option/create", "crm": crm_id})

# Option updated
def event_option_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	field_id = e.content("field")
	option_id = e.content("id")
	if not class_id or not field_id or not option_id:
		return
	name = e.content("name")
	colour = e.content("colour")
	icon = e.content("icon")
	if name != None:
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"name": name})
	if colour != None:
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"colour": colour})
	if icon != None:
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"icon": icon})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "option/update", "crm": crm_id})

# Option deleted
def event_option_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	field_id = e.content("field")
	option_id = e.content("id")
	if not class_id or not field_id or not option_id:
		return
	row_remove("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "option/delete", "crm": crm_id})

# Option reorder
def event_option_reorder(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	field_id = e.content("field")
	order = sequence(e.content("order"))
	if not class_id or not field_id or not order:
		return
	for i, option_id in enumerate(order):
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"rank": i})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "option/reorder", "crm": crm_id})

# ============================================================================
# ============================================================================
# Remote Request Handling (P2P request-response for subscriber actions)
# ============================================================================

# Required access level for each forwarded action
REQUEST_LEVELS = {
	"comment/create": "comment", "comment/update": "comment", "comment/delete": "comment",
	"object/create": "write", "object/update": "write", "object/delete": "write",
	"object/move": "write", "values/set": "write", "value/set": "write",
	"link/create": "write", "link/delete": "write",
	"attachment/delete": "write", "attachment/copy": "write",
	"class/create": "design", "class/update": "design", "class/delete": "design",
	"field/create": "design", "field/update": "design", "field/delete": "design",
	"field/reorder": "design",
	"option/create": "design", "option/update": "design", "option/delete": "design",
	"option/reorder": "design",
	"hierarchy/set": "design",
	"view/create": "design", "view/update": "design", "view/delete": "design",
	"view/reorder": "design",
}

# Handle incoming request from a subscriber
def event_request(e):
	requester = e.header("from")
	if not requester:
		e.stream.write({"error": "errors.access_denied", "code": 401})
		return
	action = e.content("action")
	params = e.content("params") or {}
	# params is read with .get throughout and action is a dict key; a list or
	# a string here aborts the handler before the access check, so any peer
	# at all could crash it.
	if type(params) != "dict" or type(action) != "string":
		e.stream.write({"error": "errors.invalid_data", "code": 400})
		return
	# Authorship and ownership are governed by the authenticated P2P sender, not
	# a content-supplied id: a content "_user" is spoofable and would let a peer
	# post as, or edit/delete the comments of, another user.
	user_id = requester
	user_name = e.content("name") or ""
	if type(user_name) != "string" or not mochi.text.valid(user_name, "display"):
		user_name = ""

	crm_id = params.get("crm")
	if type(crm_id) != "string" or not crm_id:
		e.stream.write({"error": "errors.crm_id_required", "code": 400})
		return

	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		e.stream.write({"error": "errors.crm_not_found", "code": 404})
		return

	level = REQUEST_LEVELS.get(action)
	if not level:
		e.stream.write({"error": "errors.unknown_action", "code": 400})
		return

	if not check_crm_access(requester, crm_id, level):
		e.stream.write({"error": "errors.access_denied", "code": 403})
		return

	# Dispatch to handler
	if action == "comment/create":
		result = do_comment_create(crm_id, crm, params, user_id, user_name)
	elif action == "comment/update":
		result = do_comment_update(crm_id, crm, params, user_id)
	elif action == "comment/delete":
		result = do_comment_delete(crm_id, crm, params, user_id)
	elif action == "object/create":
		result = do_object_create(crm_id, crm, params, user_id)
	elif action == "object/update":
		result = do_object_update(crm_id, crm, params, user_id)
	elif action == "object/delete":
		result = do_object_delete(crm_id, crm, params, user_id)
	elif action == "object/move":
		result = do_object_move(crm_id, crm, params, user_id)
	elif action == "values/set":
		result = do_values_set(crm_id, crm, params, user_id)
	elif action == "value/set":
		result = do_value_set(crm_id, crm, params, user_id)
	elif action == "link/create":
		result = do_link_create(crm_id, crm, params, user_id)
	elif action == "link/delete":
		result = do_link_delete(crm_id, crm, params, user_id)
	elif action == "attachment/delete":
		result = do_attachment_delete(crm_id, crm, params, user_id)
	elif action == "attachment/copy":
		result = do_attachment_copy(crm_id, crm, params, user_id)
	elif action == "class/create":
		result = do_class_create(crm_id, crm, params)
	elif action == "class/update":
		result = do_class_update(crm_id, crm, params)
	elif action == "class/delete":
		result = do_class_delete(crm_id, crm, params)
	elif action == "field/create":
		result = do_field_create(crm_id, crm, params)
	elif action == "field/update":
		result = do_field_update(crm_id, crm, params)
	elif action == "field/delete":
		result = do_field_delete(crm_id, crm, params)
	elif action == "field/reorder":
		result = do_field_reorder(crm_id, crm, params)
	elif action == "option/create":
		result = do_option_create(crm_id, crm, params)
	elif action == "option/update":
		result = do_option_update(crm_id, crm, params)
	elif action == "option/delete":
		result = do_option_delete(crm_id, crm, params)
	elif action == "option/reorder":
		result = do_option_reorder(crm_id, crm, params)
	elif action == "hierarchy/set":
		result = do_hierarchy_set(crm_id, crm, params)
	elif action == "view/create":
		result = do_view_create(crm_id, crm, params)
	elif action == "view/update":
		result = do_view_update(crm_id, crm, params)
	elif action == "view/delete":
		result = do_view_delete(crm_id, crm, params)
	elif action == "view/reorder":
		result = do_view_reorder(crm_id, crm, params)
	else:
		result = {"error": "errors.not_implemented", "code": 501}

	e.stream.write(result)

# Check a user's access level for a crm
# Check a user's access level for a CRM. The checked identity is the
# authenticated P2P sender only - honouring a content-supplied user would let
# any peer probe another identity's access levels.
def event_access_check(e):
	crm_id = e.header("to")
	user_id = e.header("from")
	result = {}
	for op in ["design", "write", "comment", "view"]:
		result[op] = check_crm_access(user_id, crm_id, op)
	e.stream.write(result)

# ============================================================================
# Remote Request Do Helpers (shared by action handlers and event_request)
# ============================================================================

# Comment helpers
def do_comment_create(crm_id, crm, params, user_id, user_name):
	object_id = params.get("object")
	content = params.get("content")
	parent = params.get("parent", "")
	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	if not content or not content.strip():
		return {"error": "errors.content_is_required", "code": 400}
	if check_length(content, 50000):
		return {"error": "errors.content_too_long", "code": 400}
	if check_length(user_name, 255):
		return {"error": "errors.name_too_long", "code": 400}
	# Same binding the HTTP owner path applies: a parent on another object's
	# thread is stored, broadcast, and rendered nowhere.
	if parent and not mochi.db.exists("select 1 from comments where id=? and object=?", parent, object_id):
		return {"error": "errors.comment_not_found", "code": 404}
	# Minted here and returned, never the caller's: a chosen id could name an
	# object's or another comment's row, and everything keyed on it.
	comment_id = mochi.uid()
	now = mochi.time.now()
	row_merge("comments", ["id"], {"id": comment_id, "object": object_id, "parent": parent, "author": user_id, "name": user_name, "content": content.strip(), "created": now, "edited": 0})
	row_set("objects", "id=?", [object_id], {"updated": now})
	log_activity(object_id, user_id, "commented")
	# Auto-watch commenter on owner's server
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": user_id, "created": now})
	# Include attachments in broadcast
	comment_attachments = attachment_list(comment_id, crm_id, "comment") or []
	comment_event = {
		"crm": crm_id, "object": object_id, "id": comment_id,
		"parent": parent, "author": user_id, "name": user_name,
		"content": content.strip(), "created": now, "user": user_id
	}
	if comment_attachments:
		comment_event["attachments"] = comment_attachments
	broadcast_event(crm_id, "comment/create", comment_event)
	# Notify owner if watching
	owner_id = get_owner_identity(crm_id)
	excerpt = (content.strip())[:80]
	notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.commented", name=user_name, excerpt=excerpt))
	# Mentions fire here, where the owner-side and P2P comment paths converge, so a
	# subscriber's mention notifies too.
	notify_mentions(object_id, crm_id, content, user_id, user_name)
	return {"id": comment_id, "author": user_id, "name": user_name,
			"content": content.strip(), "created": now}

def do_comment_update(crm_id, crm, params, user_id):
	object_id = params.get("object")
	comment_id = params.get("comment")
	content = params.get("content")
	if not object_id or not comment_id:
		return {"error": "errors.object_and_comment_id_required", "code": 400}
	# Same binding as above: the object must be in the routed crm.
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		return {"error": "errors.object_not_found", "code": 404}

	comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
	if not comment:
		return {"error": "errors.comment_not_found", "code": 404}
	if comment["author"] != user_id:
		return {"error": "errors.cannot_edit_others_comment", "code": 403}
	if not content or not content.strip():
		return {"error": "errors.content_is_required", "code": 400}
	if check_length(content, 50000):
		return {"error": "errors.content_too_long", "code": 400}
	now = mochi.time.now()
	row_set("comments", "id=?", [comment_id], {"content": content.strip(), "edited": now})
	broadcast_event(crm_id, "comment/update", {
		"crm": crm_id, "object": object_id,
		"id": comment_id, "content": content.strip(), "edited": now, "user": user_id
	})
	return {"success": True}

def do_comment_delete(crm_id, crm, params, user_id):
	object_id = params.get("object")
	comment_id = params.get("comment")
	if not object_id or not comment_id:
		return {"error": "errors.object_and_comment_id_required", "code": 400}
	# Same binding as above: the object must be in the routed crm.
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		return {"error": "errors.object_not_found", "code": 404}

	comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
	if not comment:
		return {"error": "errors.comment_not_found", "code": 404}
	if comment["author"] != user_id:
		return {"error": "errors.cannot_delete_another_user_s_comment", "code": 403}
	delete_comment_tree(comment_id, crm_id)
	broadcast_event(crm_id, "comment/delete", {
		"crm": crm_id, "object": object_id, "id": comment_id, "user": user_id
	})
	return {"success": True}

# Object helpers
def do_object_create(crm_id, crm, params, user_id):
	obj_class = params.get("class")
	if not obj_class:
		return {"error": "errors.class_is_required", "code": 400}
	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, obj_class)
	if not class_row:
		return {"error": "errors.invalid_class", "code": 400}
	parent = params.get("parent", "")
	title = params.get("title", "")
	if check_length(title, 500):
		return {"error": "errors.title_too_long", "code": 400}
	submitted, problem = create_values(params.get("values"))
	if problem:
		return {"error": problem, "code": 400}

	kept, invalid = create_values_check(crm_id, obj_class, submitted)
	if invalid:
		return {"error": invalid["key"], "args": invalid.get("args"), "code": 400}

	title_field_row = mochi.db.row("select title from classes where crm=? and id=?", crm_id, obj_class)
	title_field = title_field_row["title"] if title_field_row else ""
	object_id = mochi.uid()
	now = mochi.time.now()
	# The key is read and the row written under one lock, so a move or another
	# create beside this one cannot mint the same key. The hierarchy is judged
	# under the same lock, on the parent's class as it stands, so a class change
	# or a reparent of the parent committing first cannot leave the object under
	# a parent its class may not have.
	handle = rank_transaction(object_id)
	problem = hierarchy_check(crm_id, obj_class, parent, handle)
	if problem:
		handle.rollback()
		return {"error": "errors.hierarchy_disallowed" if problem[1] == 400 else problem[0], "code": problem[1]}
	initial_rank = rank_after_all(crm_id, None, handle)
	# Its first version, with its values in the same transaction: the create is
	# the object's first change (version_take).
	row_merge("objects", ["id"], {"id": object_id, "crm": crm_id, "class": obj_class, "parent": parent, "rank": initial_rank, "created": now, "updated": now, "version": 1}, handle)
	values = {}
	for field, value in kept.items():
		row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": value}, handle)
		values[field] = value
	if title and title_field:
		row_merge("values", ["object", "field"], {"object": object_id, "field": title_field, "value": title}, handle)
		values[title_field] = title
	# Before the commit, as each later change of the object is (events_commit).
	events_commit(crm_id, [{"event": "object/create", "data": {
		"crm": crm_id, "id": object_id, "class": obj_class,
		"parent": parent, "rank": initial_rank, "values": values,
		"created": now, "updated": now, "user": user_id, "version": 1,
	}}], handle)
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": user_id, "created": now})
	# Auto-watch assigned users, as a value set does
	for f in mochi.db.rows("select id from fields where crm=? and class=? and fieldtype='user'", crm_id, obj_class) or []:
		if values.get(f["id"]):
			row_merge("watchers", ["object", "user"], {"object": object_id, "user": values[f["id"]], "created": now})
	# After the broadcast: a subscriber sent the activity first holds no object
	# for it yet, and pulls the whole schema again to find one.
	log_activity(object_id, user_id, "created")
	# Notify owner when subscriber creates an object
	owner_id = get_owner_identity(crm_id)
	if owner_id and owner_id != user_id:
		obj = mochi.db.row("select class from objects where id=?", object_id)
		display = get_object_display(crm, obj, object_id)
		fp = mochi.entity.fingerprint(crm_id)
		url = "/crm/" + fp + "/" + object_id if fp else "/crm"
		notify("update/created", crm_id, display, mochi.app.label("notifications.body.created"), url, event_id="update/created:" + object_id)
	return {"id": object_id, "rank": initial_rank, "created": now, "updated": now, "values": values, "version": 1}

def do_object_update(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "errors.object_id_required", "code": 400}
	row = mochi.db.row("select * from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	new_class = params.get("class")
	if new_class and type(new_class) != "string":
		return {"error": "errors.invalid_value", "code": 400}
	if new_class and new_class != row["class"] and not mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, new_class):
		return {"error": "errors.class_not_found", "code": 404}
	parent = params.get("parent")
	if parent != None and type(parent) != "string":
		return {"error": "errors.invalid_value", "code": 400}
	answer = object_update(crm_id, row, parent, new_class, user_id)
	if answer.get("error"):
		return answer
	# Notify owner if watching
	owner_id = get_owner_identity(crm_id)
	notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.updated"))
	# What it wrote, with its time, which the subscriber that forwarded it
	# stamps its copy with, as a move's answer carries.
	return answer

def do_object_delete(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "errors.object_id_required", "code": 400}
	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	# Notify owner before cascade (watchers get deleted in cascade)
	owner_id = get_owner_identity(crm_id)
	notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.deleted"))
	delete_object_cascade(crm_id, object_id, user_id)
	return {"success": True}

def do_object_move(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "errors.object_id_required", "code": 400}
	row = mochi.db.row("select id, class, parent from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	field = params.get("field", "")
	if type(field) != "string":
		return {"error": "errors.invalid_value", "code": 400}
	value = params.get("value")
	if value != None and type(value) != "string":
		return {"error": "errors.invalid_value", "code": 400}
	clear = params.get("clear", "") == "true"
	# Same as the HTTP twin: every value is checked, under the move's lock,
	# before anything changes (object_move).
	row_field, row_value = row_input(params.get("row"))
	new_rank = params.get("rank")
	# Reachable over P2P from any subscriber with write access: int() on a
	# non-integer would abort the owner-side handler, so answer a clean 400.
	if new_rank != None and not mochi.text.valid(str(new_rank), "integer"):
		return {"error": "errors.invalid_value", "code": 400}
	if params.get("scope") != None and type(params.get("scope")) != "string":
		return {"error": "errors.invalid_value", "code": 400}
	# The HTTP twin's parent and place among its children in one move.
	parent = params.get("parent")
	if parent != None and type(parent) != "string":
		return {"error": "errors.invalid_value", "code": 400}
	if parent != None and params.get("promote", "") == "true":
		return {"error": "errors.invalid_value", "code": 400}
	# The subscriber that asked for the move writes what the answer names, and
	# the owner is told when watching.
	answer = object_move(crm_id, row, {
		"field": field, "value": value, "clear": clear, "lane": row_field, "row": row_value,
		"parent": parent, "promote": params.get("promote", "") == "true", "scope": params.get("scope"),
		"after": params.get("after"), "before": params.get("before"), "rank": new_rank,
	}, user_id, True)
	# Core decodes at most 10,000 elements in one array of a stream, so the
	# answer carries the moved object's key first and at most RANK_CHUNK in
	# all; the broadcasts, in chunks, bring the rest of a large spread, and the
	# clients reload on the object/ranks each lands as.
	if answer.get("ranks"):
		answer["ranks"] = ([r for r in answer["ranks"] if r["id"] == object_id] + [r for r in answer["ranks"] if r["id"] != object_id])[:RANK_CHUNK]
	return answer

# Validate a YYYY-MM-DD calendar date.
def is_iso_date(value):
	parts = value.split("-")
	if len(parts) != 3:
		return False
	if len(parts[0]) != 4 or len(parts[1]) != 2 or len(parts[2]) != 2:
		return False
	for p in parts:
		if not mochi.text.valid(p, "natural"):
			return False
	month = int(parts[1])
	day = int(parts[2])
	return month >= 1 and month <= 12 and day >= 1 and day <= 31

# value_refused(crm_id, object_id, field, value) -> whether a value a peer sent
# for a field of an object cannot be one. A user field holds an entity id or
# nothing: clients build the person's avatar address from it, and fetch it with
# the session, so a path there would name another action. Within a transaction
# (handle) the read goes through it.
def value_refused(crm_id, object_id, field, value, handle=None):
	if value == None or str(value) == "":
		return False
	row = (handle or mochi.db).row("select f.fieldtype as fieldtype from objects o join fields f on f.crm=o.crm and f.class=o.class and f.id=? where o.id=? and o.crm=?", field, object_id, crm_id)
	return row != None and row["fieldtype"] == "user" and not mochi.text.valid(str(value), "entity")

# First violation of a field's type and constraints as {"key", "args"}, or None.
# Empty values always pass ("required" is checked elsewhere); the regex
# `pattern` constraint is not enforced - Starlark has no regex API. Reads go
# through handle, within a transaction.
def validate_field_value(crm_id, class_id, field_id, value, handle=None):
	database = handle or mochi.db
	value = "" if value == None else str(value)
	if value == "":
		return None
	field = database.row("select fieldtype, min, max, minlength, maxlength from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field:
		return None
	ftype = field["fieldtype"]

	if ftype == "enumerated":
		if not database.exists("select 1 from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, value):
			return {"key": "errors.invalid_option"}

	elif ftype == "number":
		if not mochi.text.valid(value, "numeric"):
			return {"key": "errors.value_not_a_number"}
		number = float(value)
		if field["min"] != "" and mochi.text.valid(field["min"], "numeric") and number < float(field["min"]):
			return {"key": "errors.value_below_minimum", "args": {"minimum": field["min"]}}
		if field["max"] != "" and mochi.text.valid(field["max"], "numeric") and number > float(field["max"]):
			return {"key": "errors.value_above_maximum", "args": {"maximum": field["max"]}}

	elif ftype == "date":
		if not is_iso_date(value):
			return {"key": "errors.invalid_date"}
		# ISO dates compare correctly as strings.
		if field["min"] != "" and value < field["min"]:
			return {"key": "errors.value_below_minimum", "args": {"minimum": field["min"]}}
		if field["max"] != "" and value > field["max"]:
			return {"key": "errors.value_above_maximum", "args": {"maximum": field["max"]}}

	elif ftype == "text":
		length = len(value)
		if field["minlength"] and length < field["minlength"]:
			return {"key": "errors.minimum_length", "args": {"minimum": field["minlength"]}}
		if field["maxlength"] and length > field["maxlength"]:
			return {"key": "errors.maximum_length", "args": {"maximum": field["maxlength"]}}

	elif ftype == "checkbox":
		if value not in ("0", "1", "true", "false"):
			return {"key": "errors.invalid_value"}

	elif ftype == "user":
		if not mochi.text.valid(value, "entity"):
			return {"key": "errors.invalid_value"}

	elif ftype == "checklist":
		if not checklist_valid(value):
			return {"key": "errors.invalid_value"}

	return None

# Whether value is a checklist as clients write one: a JSON list of objects,
# each with a non-empty string id, a string text and a bool done. Lists stored
# before this check are repaired by the clients on read.
def checklist_valid(value):
	items = json.decode(value, None)
	if type(items) != "list":
		return False
	for item in items:
		if type(item) != "dict":
			return False
		if type(item.get("id")) != "string" or not item["id"]:
			return False
		if type(item.get("text")) != "string" or type(item.get("done")) != "bool":
			return False
	return True

# create_values(raw) -> (values, error key): the field values an object create
# carries, a JSON object of field id to string or its JSON text. None or "" is
# no values.
def create_values(raw):
	if raw == None or raw == "":
		return {}, None
	if type(raw) == "string":
		raw = json.decode(raw, None)
	if type(raw) != "dict":
		return None, "errors.invalid_value"
	for field, value in raw.items():
		if type(field) != "string" or type(value) != "string":
			return None, "errors.invalid_value"
	return raw, None

# create_values_check(crm_id, class_id, values) -> (kept, problem): the values
# of a new object that name a field of its class and are not empty, or the
# first that cannot be stored as {"key", "args"}. Runs before the object row is
# written, so a refusal creates nothing.
def create_values_check(crm_id, class_id, values):
	for value in values.values():
		if len(value) > 50000:
			return None, {"key": "errors.value_too_long"}
	fields = {}
	for f in mochi.db.rows("select id from fields where crm=? and class=?", crm_id, class_id) or []:
		fields[f["id"]] = True
	kept = {}
	for field, value in values.items():
		if field not in fields or value == "":
			continue
		invalid = validate_field_value(crm_id, class_id, field, value)
		if invalid:
			return None, invalid
		kept[field] = value
	return kept, None

# move_check(crm_id, class_id, field, value, row_field, row_value, clear) -> the
# first value a move may not write as {"key", "args"}, or None. A value is the
# column of field the object moves into, which an empty one keeps and clear
# empties, and a row value its lane of row_field, which an empty one clears.
# Runs before the move changes anything, so a refused move changes nothing,
# under the move's lock, its reads through handle.
def move_check(crm_id, class_id, field, value, row_field, row_value, clear, handle):
	for name in (field, row_field):
		if len(name) > 100:
			return {"key": "errors.field_name_too_long"}
		if name and not handle.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, name):
			return {"key": "errors.field_not_found"}
	# A value names a column; with no field it would be stored under "" and
	# shown nowhere. A clear empties the field, so it names one and no value to
	# write.
	if (value or clear) and not field:
		return {"key": "errors.field_not_found"}
	if clear and value:
		return {"key": "errors.invalid_value"}
	for name, written in ((field, value), (row_field, row_value)):
		if not written:
			continue
		if len(written) > 50000:
			return {"key": "errors.value_too_long"}
		invalid = validate_field_value(crm_id, class_id, name, written, handle)
		if invalid:
			return invalid
	return None

# Value helpers
def do_values_set(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "errors.object_id_required", "code": 400}
	row = mochi.db.row("select id, class from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	valid_fields = {}
	field_types = {}
	field_rows = mochi.db.rows("select id, name, fieldtype from fields where crm=? and class=?", crm_id, row["class"]) or []
	for f in field_rows:
		valid_fields[f["id"]] = f["name"]
		field_types[f["id"]] = f["fieldtype"]
	values = params.get("values", {})
	if type(values) != "dict":
		return {"error": "errors.invalid_value", "code": 400}
	for v in values.values():
		if check_length(v, 50000):
			return {"error": "errors.value_too_long", "code": 400}
	# Every value is checked before any is written, so a refusal writes none.
	checked = {}
	for field_id in values:
		if field_id not in valid_fields:
			continue
		new_value = values[field_id]
		invalid = validate_field_value(crm_id, row["class"], field_id, new_value)
		if invalid:
			return {"error": invalid["key"], "args": invalid.get("args"), "code": 400}
		checked[field_id] = str(new_value)
	written, version, now = values_write(crm_id, object_id, checked, user_id)
	if written:
		# Notify owner if watching
		owner_id = get_owner_identity(crm_id)
		notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.updated"))
		values_watch(object_id, written, field_types, now)
	# What it wrote, with its time and the object's version, which the
	# subscriber that forwarded it writes (values_answer).
	answer = {"success": True, "changed": list(written), "values": written, "updated": now}
	if version != None:
		answer["version"] = version
	return answer

def do_value_set(crm_id, crm, params, user_id):
	object_id = params.get("object")
	field_id = params.get("field")
	if not object_id:
		return {"error": "errors.object_id_required", "code": 400}
	if not field_id:
		return {"error": "errors.field_id_required", "code": 400}
	row = mochi.db.row("select id, class from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	field_row = mochi.db.row("select id, fieldtype from fields where crm=? and class=? and id=?", crm_id, row["class"], field_id)
	if not field_row:
		return {"error": "errors.invalid_field_for_this_class", "code": 400}
	new_value = params.get("value", "")
	if check_length(new_value, 50000):
		return {"error": "errors.value_too_long", "code": 400}
	invalid = validate_field_value(crm_id, row["class"], field_id, new_value)
	if invalid:
		return {"error": invalid["key"], "args": invalid.get("args"), "code": 400}
	written, version, now = values_write(crm_id, object_id, {field_id: str(new_value)}, user_id)
	if written:
		# Notify owner if watching
		owner_id = get_owner_identity(crm_id)
		notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.updated"))
		values_watch(object_id, written, {field_id: field_row["fieldtype"]}, now)
	# What it wrote, as do_values_set answers.
	answer = {"success": True, "values": written, "updated": now}
	if version != None:
		answer["version"] = version
	return answer

# Link helpers
def do_link_create(crm_id, crm, params, user_id):
	object_id = params.get("object")
	target_id = params.get("target")
	linktype = params.get("linktype")
	if not object_id or not target_id or not linktype:
		return {"error": "errors.object_target_and_linktype_are_required", "code": 400}
	if linktype not in ["blocks", "relates", "duplicates"]:
		return {"error": "errors.invalid_link_type", "code": 400}
	source_row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	target_row = mochi.db.row("select id from objects where id=? and crm=?", target_id, crm_id)
	if not source_row or not target_row:
		return {"error": "errors.object_not_found", "code": 404}
	if object_id == target_id:
		return {"error": "errors.cannot_link_object_to_itself", "code": 400}
	existing = mochi.db.exists("select 1 from links where source=? and target=? and linktype=?", object_id, target_id, linktype)
	if existing:
		return {"error": "errors.link_already_exists", "code": 400}
	now = mochi.time.now()
	row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": object_id, "target": target_id, "linktype": linktype, "created": now})
	log_activity(object_id, user_id, "linked", linktype, "", target_id)
	broadcast_event(crm_id, "link/create", {
		"crm": crm_id, "source": object_id,
		"target": target_id, "linktype": linktype, "created": now, "user": user_id
	})
	# Notify owner if watching
	owner_id = get_owner_identity(crm_id)
	notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.link_added"))
	return {"success": True}

def do_link_delete(crm_id, crm, params, user_id):
	object_id = params.get("object")
	target_id = params.get("target")
	linktype = params.get("linktype")
	if not object_id or not target_id or not linktype:
		return {"error": "errors.object_target_and_linktype_are_required", "code": 400}
	row_remove("links", "crm=? and source=? and target=? and linktype=?", [crm_id, object_id, target_id, linktype])
	broadcast_event(crm_id, "link/delete", {
		"crm": crm_id, "source": object_id,
		"target": target_id, "linktype": linktype, "user": user_id
	})
	# Notify owner if watching
	owner_id = get_owner_identity(crm_id)
	notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.link_removed"))
	return {"success": True}

# Attachment helper
def do_attachment_delete(crm_id, crm, params, user_id):
	attachment_id = params.get("attachment")
	object_id = params.get("object")
	if not attachment_id:
		return {"error": "errors.attachment_id_required", "code": 400}
	if object_id:
		if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
			return {"error": "errors.object_not_found", "code": 404}
	if not attachment_exists(attachment_id):
		return {"error": "errors.attachment_not_found", "code": 404}
	# Unconditional, not an else: an object the caller does hold says nothing
	# about the attachment they named, so supplying one must not stand in for
	# binding the attachment itself.
	if not attachment_in_crm(attachment_id, crm_id):
		return {"error": "errors.attachment_not_found", "code": 404}
	attachment_delete(attachment_id)
	broadcast_event(crm_id, "attachment/remove", {
		"crm": crm_id, "attachment": attachment_id
	})
	return {"success": True}

# Copies attachments onto an object, each bound to this CRM before its bytes
# are touched, with its caption and description. The copies fan out as an
# upload's do.
def do_attachment_copy(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if type(object_id) != "string" or not object_id:
		return {"error": "errors.object_id_required", "code": 400}
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		return {"error": "errors.object_not_found", "code": 404}
	ids = params.get("attachments")
	if type(ids) not in ("list", "tuple") or not ids:
		return {"error": "errors.attachment_id_required", "code": 400}
	if len(ids) > attachment_store_maximum:
		return {"error": "errors.invalid_data", "code": 400}
	for id in ids:
		if not attachment_identifier(id) or not attachment_in_crm(id, crm_id):
			return {"error": "errors.attachment_not_found", "code": 404}
	copied = []
	for id in ids:
		source = attachment_row(id)
		att = attachment_copy(id, object_id, user_id, source.get("caption", ""), source.get("description", ""))
		if att:
			copied.append(att)
	if not copied:
		return {"attachments": []}
	now = mochi.time.now()
	row_set("objects", "id=?", [object_id], {"updated": now})
	for att in copied:
		log_activity(object_id, user_id, "attached", "", "", att["name"])
	broadcast_event(crm_id, "attachment/add", {
		"crm": crm_id, "object": object_id,
		"attachments": [{"id": att["id"], "name": att["name"], "size": att["size"], "content_type": att.get("type", ""), "rank": att.get("rank", 0), "created": att.get("created", now)} for att in copied]
	})
	return {"attachments": copied}

# Class helpers
def do_class_create(crm_id, crm, params):
	name = params.get("name")
	if not name or not name.strip():
		return {"error": "errors.name_is_required", "code": 400}
	if check_length(name, 100):
		return {"error": "errors.name_too_long", "code": 400}
	class_id = structural_id(name)
	if not class_id:
		return {"error": "errors.invalid_name", "code": 400}
	existing = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id)
	if existing:
		return {"error": "errors.class_name_taken", "code": 400}
	max_rank = mochi.db.row("select max(rank) as m from classes where crm=?", crm_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0
	row_merge("classes", ["crm", "id"], {"crm": crm_id, "id": class_id, "name": name.strip(), "rank": rank, "title": "title"})
	row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": class_id, "id": "title", "name": mochi.app.label("field.title"), "fieldtype": "text", "flags": "required,sort", "rank": 0})
	row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": class_id, "parent": ""})
	broadcast_event(crm_id, "class/create", {
		"crm": crm_id, "id": class_id, "name": name.strip(), "rank": rank, "title": "title"
	})
	return {"id": class_id, "name": name.strip(), "rank": rank}

def do_class_update(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "errors.type_id_required", "code": 400}
	class_row = mochi.db.row("select * from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		return {"error": "errors.class_not_found", "code": 404}
	name = params.get("name")
	if check_length(name, 100):
		return {"error": "errors.name_too_long", "code": 400}
	if name != None and (type(name) != "string" or not name.strip()):
		return {"error": "errors.name_is_required", "code": 400}
	title_input = params.get("title")
	if check_length(title_input, 100):
		return {"error": "errors.title_too_long", "code": 400}
	if title_input != None and title_input != "":
		if not mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, title_input):
			return {"error": "errors.field_not_found", "code": 400}
	if name:
		row_set("classes", "crm=? and id=?", [crm_id, class_id], {"name": name.strip()})
	if title_input != None:
		row_set("classes", "crm=? and id=?", [crm_id, class_id], {"title": title_input})
	broadcast_event(crm_id, "class/update", {
		"crm": crm_id, "id": class_id, "name": name or class_row["name"],
		"title": title_input if title_input != None else class_row["title"]
	})
	return {"success": True}

def do_class_delete(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "errors.class_id_required", "code": 400}
	has_objects = mochi.db.exists("select 1 from objects where crm=? and class=?", crm_id, class_id)
	if has_objects:
		return {"error": "errors.class_in_use", "code": 400}
	# view_classes has a foreign key to classes(crm, id); delete its rows before
	# the class row or the delete fails with "FOREIGN KEY constraint failed".
	# Also clear hierarchy rows where this class is a parent.
	row_remove("options", "crm=? and class=?", [crm_id, class_id])
	row_remove("fields", "crm=? and class=?", [crm_id, class_id])
	row_remove("view_classes", "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", "crm=? and parent=?", [crm_id, class_id])
	row_remove("classes", "crm=? and id=?", [crm_id, class_id])
	broadcast_event(crm_id, "class/delete", {"crm": crm_id, "id": class_id})
	return {"success": True}

# Field helpers
def do_field_create(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "errors.type_id_required", "code": 400}
	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		return {"error": "errors.type_not_found", "code": 404}
	name = params.get("name")
	if not name or not name.strip():
		return {"error": "errors.name_is_required", "code": 400}
	if check_length(name, 100):
		return {"error": "errors.name_too_long", "code": 400}
	if check_length(params.get("flags"), 200):
		return {"error": "errors.value_too_long", "code": 400}
	fieldtype = params.get("fieldtype", "text")
	if fieldtype not in FIELD_TYPES:
		return {"error": "errors.invalid_field_type", "code": 400}
	field_id = structural_id(name)
	if not field_id:
		return {"error": "errors.invalid_name", "code": 400}
	existing = mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if existing:
		return {"error": "errors.a_field_with_this_name_already_exists", "code": 400}
	max_rank = mochi.db.row("select max(rank) as m from fields where crm=? and class=?", crm_id, class_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0
	flags = params.get("flags", "")
	multi = 1 if params.get("multi") == "1" or params.get("multi") == "true" else 0
	card = 1 if params.get("card") != "0" and params.get("card") != "false" else 0
	rows = safe_int(params.get("rows"), 1)
	row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": class_id, "id": field_id, "name": name.strip(), "fieldtype": fieldtype, "flags": flags, "multi": multi, "rank": rank, "card": card, "rows": rows})
	broadcast_event(crm_id, "field/create", {
		"crm": crm_id, "class": class_id, "id": field_id,
		"name": name.strip(), "fieldtype": fieldtype, "flags": flags,
		"multi": multi, "rank": rank, "card": card, "rows": rows
	})
	return {"id": field_id, "name": name.strip(), "fieldtype": fieldtype, "rank": rank}

# Every field attribute the owner HTTP path accepts. The subscriber forward and
# do_field_update both read this list, so a new attribute cannot reach one path
# and not the other.
FIELD_ATTRIBUTES = ["name", "flags", "multi", "card", "position", "rows", "id",
	"min", "max", "pattern", "minlength", "maxlength", "prefix", "suffix", "format"]

IN_CHUNK = 500

# Objects per sync/batch message (see send_crm_data).
SYNC_CHUNK = 200

def rows_in(before, ids, after=""):
	"""Run an IN (?,...) query in chunks. SQLite binds at most 32766 parameters,
	and these lists are one entry per object in the CRM."""
	out = []
	for start in range(0, len(ids), IN_CHUNK):
		chunk = ids[start:start + IN_CHUNK]
		placeholders = ",".join(["?" for _ in chunk])
		out.extend(mochi.db.rows(before + placeholders + after, *chunk) or [])
	return out

# The kinds of link between two objects.
LINK_TYPES = ["blocks", "relates", "duplicates"]

def link_type(value):
	"""Coerce a peer-supplied link type to one the validators accept. The three
	HTTP paths all refuse anything outside this list, so a link stored under
	another value could never be matched by a delete or produced by a client."""
	if type(value) == "string" and value in LINK_TYPES:
		return value
	return "relates"

# field_remove(crm_id, class_id, field_id): delete a field and every reference
# to it - the places rename_field_id rewrites. Values on the class's objects,
# the view_fields rows of the views that show the class, the view columns that
# name it, and the class's title, which becomes unset. Options go with the
# field. Activity keeps the id: it is history.
def field_remove(crm_id, class_id, field_id):
	mochi.db.execute("delete from \"values\" where field=? and object in (select id from objects where crm=? and class=?)", field_id, crm_id, class_id)
	for view in views_for_class(crm_id, class_id):
		row_remove("view_fields", "crm=? and view=? and field=?", [crm_id, view, field_id])
		for column in ["columns", "rows", "sort", "border"]:
			row_set("views", "crm=? and id=? and \"" + column + "\"=?", [crm_id, view, field_id], {column: ""})
	row_set("classes", "crm=? and id=? and title=?", [crm_id, class_id, field_id], {"title": ""})
	row_remove("options", "crm=? and class=? and field=?", [crm_id, class_id, field_id])
	row_remove("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id])

# Rename a field ID across all tables that reference it
def rename_field_id(crm_id, class_id, old_id, new_id):
	row_rekey("fields", "crm=? and class=? and id=?", [crm_id, class_id, old_id], {"id": new_id})
	row_rekey("options", "crm=? and class=? and field=?", [crm_id, class_id, old_id], {"field": new_id})
	# Re-key field old_id -> new_id across this class's objects: re-merge each value under
	# the new field id and tombstone the old (the merge upsert handles any new_id conflict).
	for _v in mochi.db.rows("select object, value from \"values\" where field=? and object in (select id from objects where crm=? and class=?)", old_id, crm_id, class_id):
		row_merge("values", ["object", "field"], {"object": _v["object"], "field": new_id, "value": _v["value"]})
		row_remove("values", "object=? and field=?", [_v["object"], old_id])
	# Field ids are scoped to their class (fields is keyed crm+class+id), so two
	# classes may each own a field called "status". Only views that actually show
	# this class may be rewritten: a view is bound to classes through
	# view_classes, and a view with no rows there shows every class.
	for view in views_for_class(crm_id, class_id):
		# view_fields is keyed (crm, view, field), so rekeying old_id onto a view
		# that already lists new_id would collide. The existing row wins - it
		# carries the rank the user chose for that field.
		if mochi.db.exists("select 1 from view_fields where crm=? and view=? and field=?", crm_id, view, new_id):
			row_remove("view_fields", "crm=? and view=? and field=?", [crm_id, view, old_id])
		else:
			row_rekey("view_fields", "crm=? and view=? and field=?", [crm_id, view, old_id], {"field": new_id})
		for column in ["columns", "rows", "sort", "border"]:
			row_set("views", "crm=? and id=? and \"" + column + "\"=?", [crm_id, view, old_id], {column: new_id})
	mochi.db.execute("update activity set field=? where field=? and object in (select id from objects where crm=? and class=?)", new_id, old_id, crm_id, class_id)
	row_set("classes", "crm=? and id=? and title=?", [crm_id, class_id, old_id], {"title": new_id})

def views_for_class(crm_id, class_id):
	"""Ids of the views that show class_id: those naming it in view_classes, plus
	those naming no class at all, which show every class."""
	rows = mochi.db.rows("select id from views where crm=? and (id in (select view from view_classes where crm=? and class=?) or id not in (select view from view_classes where crm=?))", crm_id, crm_id, class_id, crm_id) or []
	return [row["id"] for row in rows]
def do_field_update(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	if not class_id or not field_id:
		return {"error": "errors.type_and_field_id_required", "code": 400}
	field_row = mochi.db.row("select * from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field_row:
		return {"error": "errors.field_not_found", "code": 404}
	if check_length(params.get("name"), 100):
		return {"error": "errors.name_too_long", "code": 400}
	if check_length(params.get("flags"), 200):
		return {"error": "errors.value_too_long", "code": 400}
	if check_length(params.get("id"), 100):
		return {"error": "errors.value_too_long", "code": 400}
	name = params.get("name")
	flags = params.get("flags")
	multi = params.get("multi")
	card = params.get("card")
	position = params.get("position")
	rows_val = params.get("rows")
	if rows_val != None and not mochi.text.valid(str(rows_val), "numeric"):
		return {"error": "errors.invalid_value", "code": 400}
	rows_number = int(rows_val) if rows_val != None else None
	if name != None:
		if type(name) != "string" or not name.strip():
			return {"error": "errors.name_is_required", "code": 400}
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"name": name.strip()})
	if flags != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"flags": flags})
	if multi != None:
		multi_val = 1 if multi == "1" or multi == "true" else 0
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"multi": multi_val})
	if card != None:
		card_val = 1 if card == "1" or card == "true" else 0
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"card": card_val})
	if position != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"position": position})
	if rows_number != None:
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rows": rows_number})
	# Rename field ID if requested
	new_id = params.get("id")
	if new_id != None:
		new_id = new_id.strip().lower()
		if new_id and new_id != field_id:
			for ch in new_id.elems():
				if ch != "_" and not ch.isalnum():
					return {"error": "errors.invalid_field_id", "code": 400}
			if mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, new_id):
				return {"error": "errors.a_field_with_this_id_already_exists", "code": 400}
			rename_field_id(crm_id, class_id, field_id, new_id)
	update_data = {"crm": crm_id, "class": class_id, "id": new_id if (new_id != None and new_id and new_id != field_id) else field_id}
	if new_id != None and new_id and new_id != field_id:
		update_data["previous"] = field_id
	if name != None:
		update_data["name"] = name.strip()
	if flags != None:
		update_data["flags"] = flags
	if multi != None:
		update_data["multi"] = 1 if multi == "1" or multi == "true" else 0
	if card != None:
		update_data["card"] = 1 if card == "1" or card == "true" else 0
	if position != None:
		update_data["position"] = position
	if rows_number != None:
		update_data["rows"] = rows_number
	# The validation attributes, matching the owner HTTP path field for field.
	# minlength/maxlength go through safe_int there, so they do here too. They
	# are written under the id the field has now, after any rename above.
	for key in ["min", "max", "pattern", "prefix", "suffix", "format"]:
		value = params.get(key)
		if value != None:
			row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, update_data["id"]], {key: value})
			update_data[key] = value
	for key in ["minlength", "maxlength"]:
		value = params.get(key)
		if value != None:
			number = safe_int(value)
			row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, update_data["id"]], {key: number})
			update_data[key] = number
	broadcast_event(crm_id, "field/update", update_data)
	return {"success": True}

def do_field_delete(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	if not class_id or not field_id:
		return {"error": "errors.type_and_field_id_required", "code": 400}
	field_remove(crm_id, class_id, field_id)
	broadcast_event(crm_id, "field/delete", {"crm": crm_id, "class": class_id, "id": field_id})
	return {"success": True}

def do_field_reorder(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "errors.type_id_required", "code": 400}
	order_str = params.get("order", "")
	order = [f.strip() for f in order_str.split(",") if f.strip()]
	for i, field_id in enumerate(order):
		row_set("fields", "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rank": i})
	broadcast_event(crm_id, "field/reorder", {"crm": crm_id, "class": class_id, "order": order})
	return {"success": True}

# Option helpers
def do_option_create(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	if not class_id or not field_id:
		return {"error": "errors.type_and_field_id_required", "code": 400}
	field_row = mochi.db.row("select fieldtype from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field_row:
		return {"error": "errors.field_not_found", "code": 404}
	if field_row["fieldtype"] != "enumerated":
		return {"error": "errors.field_not_enumerated", "code": 400}
	name = params.get("name")
	if not name or not name.strip():
		return {"error": "errors.name_is_required", "code": 400}
	if check_length(name, 100):
		return {"error": "errors.name_too_long", "code": 400}
	if check_length(params.get("colour"), 20):
		return {"error": "errors.colour_too_long", "code": 400}
	if check_length(params.get("icon"), 100):
		return {"error": "errors.icon_too_long", "code": 400}
	option_id = structural_id(name)
	if not option_id:
		return {"error": "errors.invalid_name", "code": 400}
	existing = mochi.db.exists("select 1 from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
	if existing:
		return {"error": "errors.an_option_with_this_name_already_exists", "code": 400}
	max_rank = mochi.db.row("select max(rank) as m from options where crm=? and class=? and field=?", crm_id, class_id, field_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0
	colour = params.get("colour", "#94a3b8")
	icon = params.get("icon", "")
	row_merge("options", ["crm", "class", "field", "id"], {"crm": crm_id, "class": class_id, "field": field_id, "id": option_id, "name": name.strip(), "colour": colour, "icon": icon, "rank": rank})
	broadcast_event(crm_id, "option/create", {
		"crm": crm_id, "class": class_id, "field": field_id,
		"id": option_id, "name": name.strip(), "colour": colour, "icon": icon, "rank": rank
	})
	return {"id": option_id, "name": name.strip(), "colour": colour, "rank": rank}

def do_option_update(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	option_id = params.get("option")
	if not class_id or not field_id or not option_id:
		return {"error": "errors.option_id_required", "code": 400}
	option_row = mochi.db.row("select * from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
	if not option_row:
		return {"error": "errors.option_not_found", "code": 404}
	if check_length(params.get("name"), 100):
		return {"error": "errors.name_too_long", "code": 400}
	if check_length(params.get("colour"), 20):
		return {"error": "errors.colour_too_long", "code": 400}
	if check_length(params.get("icon"), 100):
		return {"error": "errors.icon_too_long", "code": 400}
	name = params.get("name")
	colour = params.get("colour")
	icon = params.get("icon")
	if name != None:
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"name": name.strip()})
	if colour != None:
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"colour": colour})
	if icon != None:
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"icon": icon})
	update_data = {"crm": crm_id, "class": class_id, "field": field_id, "id": option_id}
	if name != None:
		update_data["name"] = name.strip()
	if colour != None:
		update_data["colour"] = colour
	if icon != None:
		update_data["icon"] = icon
	broadcast_event(crm_id, "option/update", update_data)
	return {"success": True}

def do_option_delete(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	option_id = params.get("option")
	if not class_id or not field_id or not option_id:
		return {"error": "errors.option_id_required", "code": 400}
	row_remove("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id])
	broadcast_event(crm_id, "option/delete", {"crm": crm_id, "class": class_id, "field": field_id, "id": option_id})
	return {"success": True}

def do_option_reorder(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	if not class_id or not field_id:
		return {"error": "errors.type_and_field_id_required", "code": 400}
	order_str = params.get("order", "")
	order = [o.strip() for o in order_str.split(",") if o.strip()]
	for i, option_id in enumerate(order):
		row_set("options", "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"rank": i})
	broadcast_event(crm_id, "option/reorder", {"crm": crm_id, "class": class_id, "field": field_id, "order": order})
	return {"success": True}

# Hierarchy helper
def do_hierarchy_set(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "errors.type_id_required", "code": 400}
	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		return {"error": "errors.type_not_found", "code": 404}
	parents_str = params.get("parents")
	if parents_str == None or parents_str == "_none_":
		parents = []
	elif parents_str == "":
		parents = [""]
	else:
		parents = [p.strip() for p in parents_str.split(",")]
	row_remove("hierarchy", "crm=? and class=?", [crm_id, class_id])
	for parent in parents:
		if parent and parent != "":
			parent_exists = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, parent)
			if not parent_exists:
				continue
		row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": class_id, "parent": parent})
	broadcast_event(crm_id, "hierarchy/set", {
		"crm": crm_id, "class": class_id, "parents": hierarchy_parents(crm_id, class_id)
	})
	return {"success": True}

# View helpers
def do_view_create(crm_id, crm, params):
	name = params.get("name")
	if not name or not name.strip():
		return {"error": "errors.name_is_required", "code": 400}
	if check_length(name, 100):
		return {"error": "errors.name_too_long", "code": 400}
	for vf in ["filter", "columns", "rows", "fields", "sort", "border"]:
		if check_length(params.get(vf), 10000):
			return {"error": "errors.value_too_long", "code": 400}
	viewtype = params.get("viewtype", "board")
	if viewtype not in VIEW_TYPES:
		return {"error": "errors.invalid_view_type", "code": 400}
	view_id = structural_id(name)
	if not view_id:
		return {"error": "errors.invalid_name", "code": 400}
	existing = mochi.db.exists("select 1 from views where crm=? and id=?", crm_id, view_id)
	if existing:
		return {"error": "errors.view_name_taken", "code": 400}
	filter_str = params.get("filter", "")
	columns = params.get("columns", "")
	if viewtype == "board" and not columns:
		return {"error": "errors.columns_field_is_required_for_board_views", "code": 400}
	rows = params.get("rows", "")
	view_classes = params.get("classes", "")
	if view_classes_invalid(crm_id, view_classes):
		return {"error": "errors.class_not_found", "code": 400}
	fields = params.get("fields") or view_fields_default(crm_id, view_classes)
	sort = params.get("sort", "")
	direction = params.get("direction", "asc")
	border = params.get("border", "")
	next_rank = mochi.db.row("select coalesce(max(rank), -1) + 1 as r from views where crm=?", crm_id)
	rank = next_rank["r"] if next_rank else 0
	row_merge("views", ["crm", "id"], {"crm": crm_id, "id": view_id, "name": name.strip(), "viewtype": viewtype, "filter": filter_str, "columns": columns, "rows": rows, "sort": sort, "direction": direction, "rank": rank, "border": border})
	for i, field in enumerate(fields.split(",")):
		if field.strip():
			row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field.strip(), "rank": i})
	if view_classes:
		for cls_id in [c.strip() for c in view_classes.split(",") if c.strip()]:
			row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": cls_id})
	payload = view_payload(crm_id, view_id)
	if payload:
		broadcast_event(crm_id, "view/create", payload)
	return {"id": view_id, "name": name.strip(), "viewtype": viewtype}

def do_view_update(crm_id, crm, params):
	view_id = params.get("view")
	if not view_id:
		return {"error": "errors.view_id_required", "code": 400}
	view = mochi.db.row("select * from views where crm=? and id=?", crm_id, view_id)
	if not view:
		return {"error": "errors.view_not_found", "code": 404}
	if check_length(params.get("name"), 100):
		return {"error": "errors.name_too_long", "code": 400}
	for vf in ["filter", "columns", "rows", "fields", "sort", "border"]:
		if check_length(params.get(vf), 10000):
			return {"error": "errors.value_too_long", "code": 400}
	if view_classes_invalid(crm_id, params.get("classes")):
		return {"error": "errors.class_not_found", "code": 400}
	name = params.get("name")
	viewtype = params.get("viewtype")
	filter_str = params.get("filter")
	columns = params.get("columns")
	rows = params.get("rows")
	fields = params.get("fields")
	sort = params.get("sort")
	direction = params.get("direction")
	if name != None and name.strip() != "":
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"name": name.strip()})
	if viewtype != None and viewtype != "":
		if viewtype not in VIEW_TYPES:
			return {"error": "errors.invalid_view_type", "code": 400}
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"viewtype": viewtype})
	if filter_str != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"filter": filter_str})
	if columns != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"columns": columns})
	if rows != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"rows": rows})
	if fields != None:
		row_remove("view_fields", "crm=? and view=?", [crm_id, view_id])
		for i, field in enumerate(fields.split(",")):
			if field.strip():
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field.strip(), "rank": i})
	if sort != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"sort": sort})
	if direction != None and direction != "":
		if direction not in VIEW_DIRECTIONS:
			return {"error": "errors.invalid_direction", "code": 400}
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"direction": direction})
	border = params.get("border")
	if border != None:
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"border": border})
	view_classes_input = params.get("classes")
	if view_classes_input != None:
		row_remove("view_classes", "crm=? and view=?", [crm_id, view_id])
		if view_classes_input:
			cls_ids = [c.strip() for c in view_classes_input.split(",") if c.strip()]
			for cls_id in cls_ids:
				row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": cls_id})
	payload = view_payload(crm_id, view_id)
	if payload:
		broadcast_event(crm_id, "view/update", payload)
	return {"success": True}

def do_view_delete(crm_id, crm, params):
	view_id = params.get("view")
	if not view_id:
		return {"error": "errors.view_id_required", "code": 400}
	count = mochi.db.row("select count(*) as cnt from views where crm=?", crm_id)
	if count and count["cnt"] <= 1:
		return {"error": "errors.cannot_delete_the_last_view", "code": 400}
	row_remove("view_fields", "crm=? and view=?", [crm_id, view_id])
	row_remove("view_classes", "crm=? and view=?", [crm_id, view_id])
	row_remove("views", "crm=? and id=?", [crm_id, view_id])
	broadcast_event(crm_id, "view/delete", {"crm": crm_id, "id": view_id})
	return {"success": True}

def do_view_reorder(crm_id, crm, params):
	order_str = params.get("order", "")
	order = [v.strip() for v in order_str.split(",") if v.strip()]
	for i, view_id in enumerate(order):
		row_set("views", "crm=? and id=?", [crm_id, view_id], {"rank": i})
	broadcast_event(crm_id, "view/reorder", {"crm": crm_id, "order": order})
	return {"success": True}

