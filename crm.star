# Mochi CRM app
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: AGPL-3.0-only
# This file is part of Mochi, licensed under the GNU AGPL v3 with the
# Mochi Application Interface Exception - see license.txt and license-exception.md.

# remote_error surfaces a failed mochi.remote.request: core-authored
# transport failures (marked "transport") become a translated generic
# error with the detail kept in the server log; far-end app answers
# pass through unchanged.
def remote_error(a, response, code=502):
	if response.get("transport"):
		mochi.log.info("Remote transport error: %s", response.get("error", ""))
		a.error.label(response.get("code", code), "errors.remote")
	else:
		a.error(response.get("code", code), response.get("error", "Error"))

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

# Helper: Broadcast event to all subscribers of a CRM via the durable
# broadcast log. Sequence + log + gap-detection live in core.
def broadcast_event(crm_id, event, data, exclude=None):
	if not crm_id:
		return
	subscribers = mochi.db.rows("select id from subscribers where crm=?", crm_id)
	subscriber_ids = [s["id"] for s in subscribers]
	mochi.broadcast.send(crm_id, crm_id, subscriber_ids, "crm", event, data, exclude or "")

# error_message_timeout: core calls this when a fan-out to a subscriber aged
# out undelivered. Remove them only when the directory shows no host left
# (locations == 0) - definitely gone, not a transient outage or a server
# migration in progress.
def error_message_timeout(e):
	if e.detail.get("locations", 1) != 0:
		return
	row_remove("subscribers", ["crm", "id"], "id=?", [e.entity])

# error_subscriber_unreachable: core suspended this subscriber - every
# delivery across the whole evict window failed with no contradicting
# success - and asks us to drop them so fan-out stops paying for a dead
# host. If they return, they re-subscribe.
def error_subscriber_unreachable(e):
	row_remove("subscribers", ["crm", "id"], "id=?", [e.entity])
# error_broadcast_gap: core calls this when an unfillable broadcast gap was
# skipped and events were permanently lost. broadcast/resync can't replay a
# pruned gap, so pull a fresh full snapshot.
def error_broadcast_gap(e):
	request_resync(e.entity)

# request_resync pulls a fresh schema dump from the CRM owner when an
# incoming event references data we don't have yet. Out-of-order delivery,
# lost messages, and the strict FK enforcement on ncruces all surface as
# the same symptom — a values/update or comment/create arriving for an
# object the subscriber hasn't seen. The owner's event_schema is the
# canonical source; insert_schema applies it idempotently. Throttled so a
# burst of bad events can't spam the owner.

# idle_resync_age: how long without applying any broadcast from a subscribed
# CRM before the next view re-subscribes (the owner may have pruned us after a
# long idle). Matches core's broadcast_log_age.
idle_resync_age = 7 * 86400

def request_resync(crm_id):
	"""Returns True iff a fresh schema was actually fetched and applied."""
	row = mochi.db.row("select server, synced from crms where id=? and owner=0", crm_id)
	if not row:
		return False
	now = mochi.time.now()
	if row["synced"] and now - row["synced"] < 60:
		return False
	row_set("crms", ["id"], "id=?", [crm_id], {"synced": now})
	server = row["server"] or ""
	peer = ""
	if server:
		peer = mochi.remote.peer(server)
	schema = mochi.remote.request(crm_id, "crm", "schema", {}, peer)
	if not schema or schema.get("error"):
		return False
	insert_schema(crm_id, schema)
	mochi.broadcast.touch(crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/resynced", "crm": crm_id})
	return True

# maybe_resubscribe re-establishes a subscribed CRM with its owner when the
# subscription has gone idle (idle_resync_age). The owner's event_subscribe is
# idempotent and pushes catch-up, so a bare re-subscribe re-adds us and re-syncs;
# touch() stamps the idle timer so a quiet CRM re-subscribes at most once per
# window and a dead owner isn't re-poked per view.
def maybe_resubscribe(a, crm_id):
	user_id = a.user.identity.id if a.user else None
	if not user_id:
		return
	if not mochi.db.row("select 1 from crms where id=? and owner=0", crm_id):
		return
	if mochi.time.now() - mochi.broadcast.seen(crm_id) <= idle_resync_age:
		return
	mochi.message.send(p2p_headers(user_id, crm_id, "subscribe"), {"name": a.user.identity.name})
	mochi.broadcast.touch(crm_id)

# --- Fractional-index rank keys (#53) ---------------------------------------
# A reorder writes ONE row's key, computed between its neighbours, so per-row
# last-write-wins converges under multi-master (no whole-scope renumber, no
# whole-scope broadcast). Canonical fractional indexing (Evan Wallace's
# algorithm): a key is an integer header (length-prefixed magnitude) + a
# fractional part. Append/prepend increment/decrement the header (base-62
# counting -> logarithmic); only a true between-insert bisects the fraction.
# ASCII-sorted alphabets, so SQLite BINARY order == key order; non-numeric text
# in the INTEGER-affinity `rank` column stays text, so no column rebuild.
RANK_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
RANK_HEADERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
RANK_SMALLEST = "A00000000000000000000000000"  # 'A' + 26 zeros: smallest integer header

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
	# A key strictly between a and b (either None = before-all / after-all).
	# TRANSITIONAL tolerance (#53): during the migrate-on-replica window a paired
	# host may still hold legacy INTEGER ranks. A legacy neighbour can't be placed
	# on the canonical scale, so treat it as an open boundary instead of crashing
	# in rank_int_part — the position self-heals once both hosts converge on
	# canonical keys. REMOVE these two guards (and rank_canonical) once all hosts
	# are migrated and every rank is a canonical key.
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

def rank_move_key(crm_id, object_id, field, target_value, scope_parent, pos):
	# Fractional key for placing object_id at 1-based position `pos` within its
	# scope (a status column, or a parent's children), from the neighbours either
	# side of the drop slot. Reads only; the caller writes the one row.
	if scope_parent != None:
		others = mochi.db.rows("select id, rank from objects where crm=? and parent=? and id!=? order by rank asc", crm_id, scope_parent, object_id) or []
	else:
		others = mochi.db.rows("select o.id, o.rank from objects o left join \"values\" v on v.object = o.id and v.field=? where o.crm=? and coalesce(v.value, '')=? and o.id!=? order by o.rank asc", field, crm_id, target_value, object_id) or []
	n = len(others)
	if pos < 1:
		pos = 1
	if pos > n + 1:
		pos = n + 1
	before = others[pos - 2]["rank"] if pos >= 2 else None
	after = others[pos - 1]["rank"] if (pos - 1) < n else None
	if after == None:
		# Appending to the end of this scope: anchor on the crm-wide max so the
		# minted key is globally unique (see rank_after_all). A pure increment of
		# this scope's last re-mints keys that cards in other scopes still hold.
		return rank_after_all(crm_id, object_id)
	return rank_between(before, after)

def rank_after_all(crm_id, exclude_id):
	# A new rank key strictly greater than every existing key in the CRM
	# (excluding exclude_id, the row being moved). Appends and creates anchor on
	# the crm-wide max — not a per-column/per-parent max — so a freshly minted end
	# key is globally unique and can't collide with a key a card in another scope
	# still holds. (The #53 duplicate-key source: incrementing a per-scope max
	# re-mints keys departed cards keep; two columns whose local max was equal
	# minted the same global key.) crm-max >= any scope's last, so the new key
	# still sorts to the end of the target scope.
	if exclude_id != None:
		row = mochi.db.row("select max(rank) as r from objects where crm=? and id!=?", crm_id, exclude_id)
	else:
		row = mochi.db.row("select max(rank) as r from objects where crm=?", crm_id)
	return rank_between(row["r"] if (row and row["r"]) else None, None)

def rank_resequence(crm_id):
	# Assign fresh, globally-unique sequential keys to every object in the crm,
	# preserving the current (rank, id) order (id breaks ties between duplicate
	# keys). Deterministic and convergent across replicas; used by the #53
	# backfill/repair migrations.
	ids = mochi.db.rows("select id from objects where crm=? order by rank, id", crm_id) or []
	previous = None
	for row in ids:
		previous = rank_between(previous, None)
		row_set("objects", ["id"], "id=?", [row["id"]], {"rank": previous})

def rank_resequence_migration(crm_id):
	# Frozen copy of rank_resequence AS IT MUST RUN inside the v4/v5 migrations
	# (#191). Those run BEFORE v7 renames objects -> objects_all, so it writes the
	# base `objects` table directly instead of via reg_set (which the v7 register
	# conversion later pointed at objects_all, a table that does not exist yet at
	# v4/v5). Same deterministic keys as rank_resequence; keep this frozen even if
	# the live helper evolves further.
	ids = mochi.db.rows("select id from objects where crm=? order by rank, id", crm_id) or []
	previous = None
	for row in ids:
		previous = rank_between(previous, None)
		mochi.db.execute("update objects set rank=? where id=?", previous, row["id"])
def database_upgrade(version):
	if version == 2:
		# Drop the pre-2026-07 broadcast tables left in the app data DB when
		# broadcast state moved to the per-app system DB - inert, but stale
		# sequence/log copies mislead diagnosis.
		for table in ["sequence", "log", "acknowledged", "received"]:
			mochi.db.execute("drop table if exists " + table)

# Create database with all 17 tables
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
		populated integer not null default 1
	)""")
	mochi.db.execute("create index if not exists crms_fingerprint on crms(fingerprint)")

	# 2. subscribers - subscribers to owned crms
	mochi.db.execute("""create table if not exists subscribers (
		crm text not null references crms(id),
		id text not null,
		name text not null default '',
		subscribed integer not null,
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
		foreign key (crm, class) references classes(crm, id)
	)""")
	mochi.db.execute("create index if not exists objects_crm on objects(crm)")
	mochi.db.execute("create index if not exists objects_class on objects(crm, class)")
	mochi.db.execute("create index if not exists objects_parent on objects(parent)")
	mochi.db.execute("create index if not exists objects_rank on objects(rank)")
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

	# 12. values - field values on objects
	mochi.db.execute("""create table if not exists "values" (
		object text not null references objects(id),
		field text not null,
		value text not null default '',
		primary key (object, field)
	)""")
	mochi.db.execute("create index if not exists values_object on \"values\"(object)")
	mochi.db.execute("create index if not exists values_owner on \"values\"(value) where field='owner'")

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

	# 15. watchers - users subscribed to object updates
	mochi.db.execute("""create table if not exists watchers (
		object text not null references objects(id),
		user text not null,
		created integer not null,
		primary key (object, user)
	)""")
	mochi.db.execute("create index if not exists watchers_user on watchers(user)")

def row_merge(table, keys, row):
	cols = list(row)
	fields = [c for c in cols if c not in keys]
	conflict = "do update set " + ", ".join(["\"" + c + "\"=excluded.\"" + c + "\"" for c in fields]) if fields else "do nothing"
	mochi.db.execute("insert into \"" + table + "\" (" + ", ".join(["\"" + c + "\"" for c in cols]) + ") values (" + ", ".join(["?" for c in cols]) + ") on conflict (" + ", ".join(["\"" + k + "\"" for k in keys]) + ") " + conflict, *[row[c] for c in cols])

def row_set(table, keys, where, args, updates):
	fields = list(updates)
	mochi.db.execute("update \"" + table + "\" set " + ", ".join(["\"" + c + "\"=?" for c in fields]) + " where (" + where + ")", *([updates[c] for c in fields] + list(args)))

def row_remove(table, keys, where, args):
	mochi.db.execute("delete from \"" + table + "\" where (" + where + ")", *args)

def row_rekey(table, keys, where, args, newkeys):
	fields = list(newkeys)
	mochi.db.execute("update \"" + table + "\" set " + ", ".join(["\"" + c + "\"=?" for c in fields]) + " where (" + where + ")", *([newkeys[c] for c in fields] + list(args)))

# ============================================================================
# Templates
# ============================================================================

def safe_int(value, default=0):
	"""Convert value to int, returning default if not a valid integer."""
	s = str(value) if value else ""
	if not s:
		return default
	if s[0] == "-":
		return int(s) if s[1:].isdigit() else default
	return int(s) if s.isdigit() else default

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

# Build the BCP 47 fallback chain for a language tag. Mirrors core's
# language_fallbacks (lower-cased, parents stripped one subtag at a time,
# always ending with "en"). The resolver caller skips uninstalled tags.
def language_fallbacks(lang):
	lang = lang.strip().lower() if lang else ""
	if lang == "" or lang == "en":
		return ["en"]
	chain = [lang]
	parent = strip_subtag(lang)
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

# Apply a template to a crm by loading from JSON or from provided data.
# `template_id` selects the labels directory for {labels.X} substitution; pass
# the originating template's id when applying user-supplied data so placeholders
# resolve correctly. Missing template_id or absent labels dir means no
# substitution — literal strings pass through unchanged (back-compat with
# user-exported templates).
def apply_template(crm_id, data=None, lang="en", template_id="crm"):
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
		row_merge("classes", ["crm", "id"], {"crm": crm_id, "id": t["id"], "name": substitute_labels(t["name"], labels), "rank": t.get("rank", 0), "title": t.get("title", "title")})

	# Set hierarchy for each class
	for cls_id, parents in data.get("hierarchy", {}).items():
		for parent in parents:
			row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": cls_id, "parent": parent})

	# Create fields for each class
	for cls_id, fields in data.get("fields", {}).items():
		for f in fields:
			row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": cls_id, "id": f["id"], "name": substitute_labels(f["name"], labels), "fieldtype": f.get("fieldtype", "text"), "flags": f.get("flags", ""), "multi": f.get("multi", 0), "rank": f.get("rank", 0), "min": f.get("min", ""), "max": f.get("max", ""), "pattern": f.get("pattern", ""), "minlength": f.get("minlength", 0), "maxlength": f.get("maxlength", 0), "prefix": f.get("prefix", ""), "suffix": f.get("suffix", ""), "format": f.get("format", ""), "card": f.get("card", 0), "position": f.get("position", ""), "rows": f.get("rows", 1)})

	# Create options for each class's enumerated fields
	for cls_id, class_options in data.get("options", {}).items():
		for field_id, field_options in class_options.items():
			for opt in field_options:
				row_merge("options", ["crm", "class", "field", "id"], {"crm": crm_id, "class": cls_id, "field": field_id, "id": opt["id"], "name": substitute_labels(opt["name"], labels), "colour": opt.get("colour", "#94a3b8"), "icon": opt.get("icon", ""), "rank": opt.get("rank", 0)})

	# Create views
	for i, v in enumerate(data.get("views", [])):
		row_merge("views", ["crm", "id"], {"crm": crm_id, "id": v["id"], "name": substitute_labels(v["name"], labels), "viewtype": v.get("viewtype", "board"), "filter": v.get("filter", ""), "columns": v.get("columns", ""), "rows": v.get("rows", ""), "sort": v.get("sort", ""), "direction": v.get("direction", "asc"), "rank": i, "border": v.get("border", "")})
		# Add view classes if specified
		for vclass in v.get("classes", []):
			row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": v["id"], "class": vclass})
		# Add fields
		fields = v.get("fields", "").split(",")
		for j, field in enumerate(fields):
			if field.strip():
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": v["id"], "field": field.strip(), "rank": j})

# Snapshot the crm design - classes, fields, options, hierarchy, and views -
# as template JSON. The snapshot contains literal strings (whatever the CRM
# DB currently holds) rather than {labels.X} placeholders — it is a copy of
# the user's live CRM, not a Mochi-shipped multi-language template. Applying
# it via design/import writes those literal names verbatim. Shared by
# design/export and data/export.
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
	for c in class_rows:
		parents = mochi.db.rows("select parent from hierarchy where crm=? and class=?", crm_id, c["id"]) or []
		if parents:
			hierarchy[c["id"]] = [p["parent"] for p in parents]

	# Read fields
	fields = {}
	for c in class_rows:
		class_fields = mochi.db.rows(
			"select id, name, fieldtype, flags, multi, rank, min, max, pattern, minlength, maxlength, prefix, suffix, format, card, position, rows from fields where crm=? and class=? order by rank",
			crm_id, c["id"]
		) or []
		if class_fields:
			fields[c["id"]] = []
			for f in class_fields:
				field = {
					"id": f["id"],
					"name": f["name"],
					"fieldtype": f["fieldtype"],
					"flags": f["flags"],
					"card": f["card"],
					"rank": f["rank"],
					"rows": f["rows"],
				}
				if f["multi"]:
					field["multi"] = f["multi"]
				if f["position"]:
					field["position"] = f["position"]
				if f["min"]:
					field["min"] = f["min"]
				if f["max"]:
					field["max"] = f["max"]
				if f["pattern"]:
					field["pattern"] = f["pattern"]
				if f["minlength"]:
					field["minlength"] = f["minlength"]
				if f["maxlength"]:
					field["maxlength"] = f["maxlength"]
				if f["prefix"]:
					field["prefix"] = f["prefix"]
				if f["suffix"]:
					field["suffix"] = f["suffix"]
				if f["format"]:
					field["format"] = f["format"]
				fields[c["id"]].append(field)

	# Read options
	options = {}
	for c in class_rows:
		class_options = {}
		for f in (fields.get(c["id"], [])):
			if f["fieldtype"] == "enumerated":
				field_options = mochi.db.rows(
					"select id, name, colour, icon, rank from options where crm=? and class=? and field=? order by rank",
					crm_id, c["id"], f["id"]
				) or []
				if field_options:
					opts = []
					for opt in field_options:
						o = {
							"id": opt["id"],
							"name": opt["name"],
							"colour": opt["colour"],
							"rank": opt["rank"],
						}
						if opt["icon"]:
							o["icon"] = opt["icon"]
						opts.append(o)
					class_options[f["id"]] = opts
		if class_options:
			options[c["id"]] = class_options

	# Read views
	views = []
	view_rows = mochi.db.rows("select id, name, viewtype, filter, columns, rows, sort, direction, rank, border from views where crm=? order by rank", crm_id) or []
	for v in view_rows:
		view = {
			"id": v["id"],
			"name": v["name"],
			"viewtype": v["viewtype"],
		}
		if v["filter"]:
			view["filter"] = v["filter"]
		if v["columns"]:
			view["columns"] = v["columns"]
		if v["rows"]:
			view["rows"] = v["rows"]
		if v["sort"]:
			view["sort"] = v["sort"]
		if v["direction"] and v["direction"] != "asc":
			view["direction"] = v["direction"]
		if v["border"]:
			view["border"] = v["border"]
		# View fields
		view_fields = mochi.db.rows("select field from view_fields where crm=? and view=? order by rank", crm_id, v["id"]) or []
		if view_fields:
			view["fields"] = ",".join([vf["field"] for vf in view_fields])
		# View classes
		view_classes = mochi.db.rows("select class from view_classes where crm=? and view=?", crm_id, v["id"]) or []
		if view_classes:
			view["classes"] = [vc["class"] for vc in view_classes]
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

# Import a design from template JSON, replacing the current design
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
	template_version = safe_int(a.input("template_version"))
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
		data = json.decode(data_str)
	elif template_id:
		templates = get_templates(lang)
		if template_id not in templates:
			a.error.label(400, "errors.invalid_template")
			return
		content = mochi.app.asset.read("templates/" + template_id + ".json")
		data = json.decode(str(content))
		template_version = templates[template_id]["version"]
	else:
		a.error.label(400, "errors.design_data_or_template_is_required")
		return

	# Delete existing design in correct order (foreign key dependencies)
	row_remove("view_fields", ["crm", "view", "field"], "crm=?", [crm_id])
	row_remove("view_classes", ["crm", "view", "class"], "crm=?", [crm_id])
	row_remove("views", ["crm", "id"], "crm=?", [crm_id])
	row_remove("options", ["crm", "class", "field", "id"], "crm=?", [crm_id])
	row_remove("fields", ["crm", "class", "id"], "crm=?", [crm_id])
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=?", [crm_id])
	row_remove("classes", ["crm", "id"], "crm=?", [crm_id])
	# Apply the new design. template_id is passed so {labels.X} placeholders in
	# Mochi-shipped templates resolve; user-exported templates with literal
	# names pass through unchanged because substitute_labels short-circuits
	# when no placeholder is present.
	apply_template(crm_id, data, lang, template_id)

	# Update template tracking
	row_set("crms", ["id"], "id=?", [crm_id], {"template": template_id, "template_version": template_version})

	return {"data": {"success": True}}

# Collect an object's (or comment's) attachments with base64-encoded file
# bytes for a data export. mochi.attachment.data fetches remote bytes over
# P2P for subscribed crms. An attachment whose bytes cannot be read (deleted
# file, unreachable owner) is skipped rather than failing the whole export.
def export_attachments(object_id, crm_id):
	result = []
	for att in mochi.attachment.list(object_id, crm_id) or []:
		data = mochi.attachment.data(att["id"])
		if data == None:
			continue
		result.append({
			"name": att["name"],
			"content_type": att.get("content_type", ""),
			"caption": att.get("caption", ""),
			"description": att.get("description", ""),
			"data": mochi.encode.base64(data),
		})
	return result

# Pre-fetch attachment bytes for a data export. A remote crm fetches each
# attachment's bytes over P2P on first use, and a large crm cannot fetch
# them all inside one action's time budget - so this action warms the local
# cache for up to a minute and reports how many attachments remain. Callers
# loop until remaining is zero, then run data/export.
def action_data_export_warm(a):

	crm_id, crm = require_crm(a, "view")
	if not crm_id:
		return

	identifiers = []
	for row in mochi.db.rows("select id from objects where crm=? order by rank, id", crm_id) or []:
		for att in mochi.attachment.list(row["id"], crm_id) or []:
			identifiers.append(att["id"])
		for c in mochi.db.rows("select id from comments where object=?", row["id"]) or []:
			for att in mochi.attachment.list(c["id"], crm_id) or []:
				identifiers.append(att["id"])

	start = mochi.time.now()
	for i, identifier in enumerate(identifiers):
		if mochi.time.now() - start > 60:
			return {"data": {"attachments": len(identifiers), "remaining": len(identifiers) - i}}
		mochi.attachment.data(identifier)

	return {"data": {"attachments": len(identifiers), "remaining": 0}}

# Export the crm's data as JSON (format 2), together with a design snapshot
# so the file alone fully reproduces the crm on any instance (the source
# design may be customized or from a different template version than the
# destination's built-in templates). Includes the crm metadata, objects with
# field values, comments, attachments (base64 file bytes), and activity
# history, plus links. Watchers are per-user notification state and are not
# included. Objects whose parent is missing locally - a subscriber replica
# can drift when events are missed - are pruned along with links that
# reference them, so the file always passes its own import. Objects are
# ordered by rank so an import preserves their order.
def action_data_export(a):

	# Remote crms export from the subscriber's replica - the same tables the
	# board reads - so the file matches what the user sees.
	crm_id, crm = require_crm(a, "view")
	if not crm_id:
		return

	# Values are filtered against the design snapshot: a field removed from
	# the design can leave orphan value rows, which the app never renders -
	# exporting them would make the file fail its own import.
	design = design_export(crm_id)
	declared = {}
	for class_id, class_fields in design["fields"].items():
		for f in class_fields:
			declared[class_id + "/" + f["id"]] = True

	rows = mochi.db.rows("select id, class, parent, created, updated from objects where crm=? order by rank, id", crm_id) or []

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
		for v in mochi.db.rows("select field, value from \"values\" where object=?", row["id"]) or []:
			if v["value"] != "" and (row["class"] + "/" + v["field"]) in declared:
				values[v["field"]] = v["value"]
		if values:
			object["values"] = values
		comments = []
		for c in mochi.db.rows("select id, parent, author, name, content, created, edited from comments where object=? order by created, id", row["id"]) or []:
			comment = {
				"id": c["id"],
				"author": c["author"],
				"name": c["name"],
				"content": c["content"],
				"created": c["created"],
			}
			if c["parent"]:
				comment["parent"] = c["parent"]
			if c["edited"]:
				comment["edited"] = c["edited"]
			attachments = export_attachments(c["id"], crm_id)
			if attachments:
				comment["attachments"] = attachments
			comments.append(comment)
		if comments:
			object["comments"] = comments
		attachments = export_attachments(row["id"], crm_id)
		if attachments:
			object["attachments"] = attachments
		activity = []
		for act in mochi.db.rows("select user, action, field, oldvalue, newvalue, created from activity where object=? order by created, id", row["id"]) or []:
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
		"format": 2,
		"crm": {"name": crm["name"], "description": crm["description"]},
		"design": design,
		"objects": objects,
	}
	if links:
		result["links"] = links
	return {"data": result}

# Validate and decode a container's attachment list in place for an import:
# each entry must be a dict with a name and base64 data, and "data" is
# replaced with the decoded bytes so the write phase never re-decodes.
# Returns False on any invalid entry.
def import_attachments_decode(container):
	attachments = container.get("attachments") or []
	if type(attachments) != "list":
		return False
	for att in attachments:
		if type(att) != "dict" or not att.get("name") or type(att.get("data")) != "string":
			return False
		data = mochi.decode.base64(att["data"])
		if data == None:
			return False
		att["data"] = data
	return True

# Import data from a data/export snapshot: objects with field values,
# comments, attachments (format 2, base64 file bytes), and activity history,
# plus links. Objects and comments get fresh ids; in-file references
# (parents, links, comment threads) are remapped to the new ids, so importing
# the same snapshot twice creates two copies. Objects are appended below
# existing objects in file order. The crm's design must already contain every
# class and field id the snapshot references - apply the snapshot's embedded
# design (or the matching design/export) first via design/import; any
# "design" key in the snapshot itself is ignored here. Format 1 files (no
# attachments or activity) import unchanged. Everything is validated before
# anything is written.
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

	data_string = a.input("data")
	if not data_string:
		# Large imports upload the export as a multipart file part: form
		# fields cap out at a few megabytes at the HTTP layer, while file
		# parts spool to disk.
		upload = a.file("file")
		if upload:
			data_string = str(upload["data"])
	if not data_string:
		a.error.label(400, "errors.data_is_required")
		return
	# 1GB, matching the per-attachment cap: attachment file bytes travel
	# base64-encoded inside the JSON
	if len(data_string) > 1000000000:
		a.error.label(400, "errors.data_too_large")
		return
	data = json.decode(data_string, None)
	if type(data) != "dict":
		a.error.label(400, "errors.invalid_data")
		return

	objects = data.get("objects") or []
	links = data.get("links") or []
	if type(objects) != "list" or type(links) != "list":
		a.error.label(400, "errors.invalid_data")
		return
	if not objects and not links:
		a.error.label(400, "errors.nothing_to_import")
		return

	# Current design, for validation
	classes = {}
	for c in mochi.db.rows("select id from classes where crm=?", crm_id) or []:
		classes[c["id"]] = True
	fields = {}
	for f in mochi.db.rows("select class, id from fields where crm=?", crm_id) or []:
		fields[f["class"] + "/" + f["id"]] = True
	hierarchy = {}
	for h in mochi.db.rows("select class, parent from hierarchy where crm=?", crm_id) or []:
		hierarchy[h["class"] + "/" + h["parent"]] = True

	# File-local object ids, for remapping and parent class lookups
	imported = {}
	for o in objects:
		if type(o) != "dict" or not o.get("id") or not o.get("class"):
			a.error.label(400, "errors.invalid_data")
			return
		imported[o["id"]] = o["class"]

	# Validate everything before writing anything
	for o in objects:
		if o["class"] not in classes:
			a.error.label(400, "errors.unknown_class", name=o["class"])
			return
		parent = o.get("parent") or ""
		parent_class = ""
		if parent:
			if parent in imported:
				parent_class = imported[parent]
			else:
				row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
				if not row:
					a.error.label(404, "errors.parent_object_not_found")
					return
				parent_class = row["class"]
		if (o["class"] + "/" + parent_class) not in hierarchy:
			a.error.label(400, "errors.hierarchy_disallowed")
			return
		values = o.get("values") or {}
		if type(values) != "dict":
			a.error.label(400, "errors.invalid_data")
			return
		comments = o.get("comments") or []
		if type(comments) != "list":
			a.error.label(400, "errors.invalid_data")
			return
		for c in comments:
			if type(c) != "dict" or not c.get("content"):
				a.error.label(400, "errors.invalid_data")
				return
			if not import_attachments_decode(c):
				a.error.label(400, "errors.invalid_data")
				return
		if not import_attachments_decode(o):
			a.error.label(400, "errors.invalid_data")
			return
		activity = o.get("activity") or []
		if type(activity) != "list":
			a.error.label(400, "errors.invalid_data")
			return
		for act in activity:
			if type(act) != "dict" or not act.get("action"):
				a.error.label(400, "errors.invalid_data")
				return
	for l in links:
		if type(l) != "dict" or not l.get("source") or not l.get("target") or not l.get("linktype"):
			a.error.label(400, "errors.invalid_data")
			return
		for end in [l["source"], l["target"]]:
			if end not in imported and not mochi.db.exists("select 1 from objects where id=? and crm=?", end, crm_id):
				a.error.label(400, "errors.invalid_link")
				return

	now = mochi.time.now()
	user = a.user.identity.id

	# Fresh ids for every imported object, assigned up front so forward
	# references (a parent later in the file) remap correctly
	remap = {}
	for o in objects:
		remap[o["id"]] = mochi.uid()

	# Append below the crm-wide maximum rank, in file order (see rank_after_all)
	row = mochi.db.row("select max(rank) as r from objects where crm=?", crm_id)
	previous = row["r"] if (row and row["r"]) else None

	comment_count = 0
	attachment_count = 0
	for o in objects:
		object_id = remap[o["id"]]
		parent = o.get("parent") or ""
		parent = remap.get(parent, parent)
		previous = rank_between(previous, None)
		created = safe_int(o.get("created")) or now
		updated = safe_int(o.get("updated")) or now
		row_merge("objects", ["id"], {"id": object_id, "crm": crm_id, "class": o["class"], "parent": parent, "rank": previous, "created": created, "updated": updated})
		# Values for fields the design doesn't declare are skipped, not
		# rejected: older exports can carry orphan values from fields that
		# were later removed from the design, and the app never renders them.
		for field, value in (o.get("values") or {}).items():
			if value != "" and (o["class"] + "/" + field) in fields:
				row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": str(value)})
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
			row_merge("comments", ["id"], {"id": comment_ids[i], "object": object_id, "parent": comment_parent, "author": c.get("author") or user, "name": c.get("name") or a.user.identity.name, "content": str(c["content"]), "created": safe_int(c.get("created")) or now, "edited": safe_int(c.get("edited"))})
			comment_count += 1
			for att in (c.get("attachments") or []):
				mochi.attachment.create(comment_ids[i], att["name"], att["data"], att.get("content_type") or "", att.get("caption") or "", att.get("description") or "")
				attachment_count += 1
		for att in (o.get("attachments") or []):
			mochi.attachment.create(object_id, att["name"], att["data"], att.get("content_type") or "", att.get("caption") or "", att.get("description") or "")
			attachment_count += 1
		file_activity = o.get("activity") or []
		if file_activity:
			for act in file_activity:
				mochi.db.execute(
					"insert into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
					mochi.uid(), object_id, act.get("user") or user, str(act["action"]), str(act.get("field") or ""), str(act.get("oldvalue") or ""), str(act.get("newvalue") or ""), safe_int(act.get("created")) or now
				)
		else:
			mochi.db.execute(
				"insert into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, 'created', '', '', '', ?)",
				mochi.uid(), object_id, user, now
			)

	for l in links:
		source = remap.get(l["source"], l["source"])
		target = remap.get(l["target"], l["target"])
		row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": source, "target": target, "linktype": str(l["linktype"]), "created": safe_int(l.get("created")) or now})

	row_set("crms", ["id"], "id=?", [crm_id], {"updated": now})

	# Push a full snapshot to every subscriber - event_sync_batch applies it
	# idempotently, so this replaces per-record broadcasts for bulk changes
	for s in mochi.db.rows("select id from subscribers where crm=?", crm_id) or []:
		send_crm_data(crm_id, s["id"])

	return {"data": {"objects": len(objects), "comments": comment_count, "attachments": attachment_count, "links": len(links)}}

# ============================================================================
# CRM Actions
# ============================================================================

# List available templates
# List user's crms
def action_crm_list(a):

	rows = mochi.db.rows("""select p.id, p.name, p.description, p.owner, p.server, p.created, p.updated,
		(select s.name from subscribers s where s.crm=p.id order by s.subscribed asc limit 1) as ownername
		from crms p order by p.updated desc""")
	crms = []
	for row in rows or []:
		crms.append({
			"id": row["id"],
			"fingerprint": mochi.entity.fingerprint(row["id"]),
			"name": row["name"],
			"description": row["description"],
			"owner": row["owner"],
			"ownername": row["ownername"] or "",
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
	privacy = a.input("privacy") or "private"

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

	# Set up access control
	resource = "crm/" + entity
	if privacy == "public":
		mochi.access.allow("*", resource, "view", creator)
		mochi.access.allow("+", resource, "comment", creator)
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

	# Reclaim old register tombstones on CRM open (a low-frequency path).

	row = mochi.db.row("select id, name, description, owner, server, template, template_version, created, updated, populated from crms where id=?", crm_id)
	if not row:
		a.error.label(404, "errors.crm_not_found")
		return

	# Re-establish with the owner if this subscription has gone idle.
	maybe_resubscribe(a, crm_id)

	# Get classes
	classes = mochi.db.rows("select id, name, rank, title from classes where crm=? order by rank", crm_id) or []

	# Get all fields in one query, group by class
	fields = {}
	all_fields = mochi.db.rows("select class, id, name, fieldtype, flags, multi, rank, card, position, rows from fields where crm=? order by class, rank", crm_id) or []
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
	else:
		server = row["server"] or ""
		peer = mochi.remote.peer(server) if server else None
		response = mochi.remote.request(crm_id, "crm", "access/check", {
			"user": a.user.identity.id,
		}, peer)
		if response:
			if response.get("design"):
				access = "design"
			elif response.get("write"):
				access = "write"
			elif response.get("comment"):
				access = "comment"
			elif response.get("view"):
				access = "view"
			else:
				a.error.label(403, "errors.access_denied")
				return
		else:
			a.error.label(403, "errors.access_denied")
			return

	return {"data": {
		"crm": {
			"id": row["id"],
			"fingerprint": mochi.entity.fingerprint(row["id"]),
			"name": row["name"],
			"description": row["description"],
			"owner": row["owner"],
			"server": row["server"],
			"template": row["template"],
			"template_version": row["template_version"],
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
		row_set("crms", ["id"], "id=?", [crm_id], {"name": name, "updated": now})
		mochi.entity.update(crm_id, name=name)

	if a.input("description") != None:
		if len(description) > 10000:
			a.error.label(400, "errors.description_too_long")
			return
		row_set("crms", ["id"], "id=?", [crm_id], {"description": description, "updated": now})
	update = {"crm": crm_id}
	if name:
		update["name"] = name
	if a.input("description") != None:
		update["description"] = description
	broadcast_event(crm_id, "crm/update", update)

	return {"data": {"success": True}}

# Force a fresh schema pull from the CRM owner. Mirrors action_project_resync
# in the projects app — subscribers fall behind when an inbound event
# references data they don't have. The event handlers self-heal via
# request_resync on the next bad event; this action lets the UI / a user
# trigger it on demand.
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
	row_set("crms", ["id"], "id=?", [crm_id], {"synced": 0})
	synced = request_resync(crm_id)
	return {"data": {"synced": synced}}

# Delete crm
# Remove every local row of a CRM — physical deletes, NOT tombstones. Used
# only by the whole-CRM cleanup paths (unsubscribe, owner delete, the owner's
# deleted notice): those are per-host housekeeping, not user-intent removals
# that must converge, and tombstones there poison a later re-subscribe — the
# sync import (and the old insert-or-ignore) skips rows that still exist in
# <t>_all, so a re-subscribed CRM would come back as an empty shell with every
# object and comment invisible (#466 follow-up, mirrors projects). Each
# execute pair-replicates as one statement, so the user's own hosts purge
# identically. Children before parents so the foreign keys stay satisfied.
def purge_crm(crm_id):
	mochi.db.execute("delete from watchers where object in (select id from objects where crm=?)", crm_id)
	mochi.db.execute("delete from activity where object in (select id from objects where crm=?)", crm_id)
	mochi.db.execute("delete from comments where object in (select id from objects where crm=?)", crm_id)
	mochi.db.execute("delete from \"values\" where object in (select id from objects where crm=?)", crm_id)
	mochi.db.execute("delete from links where crm=?", crm_id)
	mochi.db.execute("delete from objects where crm=?", crm_id)
	mochi.db.execute("delete from view_fields where crm=?", crm_id)
	mochi.db.execute("delete from view_classes where crm=?", crm_id)
	mochi.db.execute("delete from views where crm=?", crm_id)
	mochi.db.execute("delete from options where crm=?", crm_id)
	mochi.db.execute("delete from fields where crm=?", crm_id)
	mochi.db.execute("delete from hierarchy where crm=?", crm_id)
	mochi.db.execute("delete from classes where crm=?", crm_id)
	mochi.db.execute("delete from subscribers where crm=?", crm_id)
	mochi.db.execute("delete from crms where id=?", crm_id)

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

	delete_crm_comment_attachments(crm_id)
	for obj in (mochi.db.rows("select id from objects where crm=?", crm_id) or []):
		mochi.attachment.clear(obj["id"])
	# Notify subscribers that crm is being deleted (before purging the
	# subscriber list). Send from the CRM entity so receivers can verify the
	# sender, matching broadcast_event and the verify_subscription check.
	subscribers = mochi.db.rows("select id from subscribers where crm=?", crm_id)
	for sub in subscribers:
		mochi.message.send(p2p_headers(crm_id, sub["id"], "deleted"), {"crm": crm_id})

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
			people[sub["id"]] = {"id": sub["id"], "name": sub["name"]}

	# Add unique owners from object values
	owners = mochi.db.rows(
		"select distinct value from \"values\" where field='owner' and value != '' and object in (select id from objects where crm=?)",
		crm_id
	) or []
	for owner in owners:
		owner_id = owner["value"]
		if owner_id and owner_id not in people:
			# Resolve owner name from entity
			name = mochi.entity.name(owner_id) or owner_id[:9]
			people[owner_id] = {"id": owner_id, "name": name}

	return {"data": {"people": list(people.values())}}

# ============================================================================
# Access Control
# ============================================================================

# Access levels for crms (from most to least permissive)
ACCESS_LEVELS = ["design", "write", "comment", "view"]

# Check if a user has cumulative access to a crm at the given level
def check_crm_access(user_id, crm_id, level):
	resource = "crm/" + crm_id
	if mochi.access.check(user_id, resource, "*"):
		return True
	levels = ["view", "comment", "write", "design"]
	if level in levels:
		idx = levels.index(level)
		for l in levels[idx:]:
			if mochi.access.check(user_id, resource, l):
				return True
	return False

# Forward a subscriber action to the crm owner via P2P. `handled` names error
# keys the CALLER recovers from itself — those return the raw error dict
# instead of writing the response, so the caller can fall back (e.g. the
# phantom-comment cleanup in action_comment_delete).
def forward_to_owner(a, crm_id, action, params, handled=None):
	# Authorship is set from the authenticated P2P sender on the owner side, so
	# we only pass the display name here, not an identity the owner would trust.
	params["_name"] = a.user.identity.name
	# Look up the server for this remote crm and resolve peer
	server_row = mochi.db.row("select server from crms where id=?", crm_id)
	server = server_row["server"] if server_row else ""
	peer = mochi.remote.peer(server) if server else None
	result = mochi.remote.request(crm_id, "crm", "request", {
		"action": action,
		"params": params,
	}, peer)
	if not result:
		a.error.label(502, "errors.could_not_reach_crm_owner")
		return None
	if result.get("error"):
		if handled and result["error"] in handled:
			return {"error": result["error"], "code": result.get("code", 500), "args": result.get("args")}
		# The error field is a label key; resolve it in the requester's language,
		# with any ICU args the owner returned alongside it.
		a.error.label(result.get("code", 500), result["error"], **(result.get("args") or {}))
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
	rules = mochi.access.list.resource(resource)

	# Resolve names for rules and mark owner
	filtered_rules = []
	for rule in rules:
		subject = rule.get("subject", "")
		# Mark owner rules
		if subject == owner.get("id"):
			rule["isOwner"] = True
		# Resolve names for non-special subjects
		if subject and subject not in ("*", "+") and not subject.startswith("#"):
			if subject.startswith("@"):
				# Look up group name
				group_id = subject[1:]
				group = mochi.group.get(group_id)
				rule["name"] = group.get("name", group_id) if group else subject
			else:
				# Look up entity name
				name = mochi.entity.name(subject)
				rule["name"] = name if name else subject[:9]
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
		a.error.label(400, "errors.subject_is_required")
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

	# Revoke all existing rules for this subject first (including wildcard)
	for op in ACCESS_LEVELS + ["*"]:
		mochi.access.revoke(subject, resource, op)

	# Then set the new level
	granter = a.user.identity.id
	if level == "none":
		# Store deny rules for all levels to block access
		for op in ACCESS_LEVELS:
			mochi.access.deny(subject, resource, op, granter)
	else:
		# Store a single allow rule for the level
		mochi.access.allow(subject, resource, level, granter)

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
		a.error.label(400, "errors.subject_is_required")
		return
	if len(subject) > 255:
		a.error.label(400, "errors.subject_too_long")
		return

	resource = "crm/" + crm_id

	# Revoke all rules for this subject
	for op in ACCESS_LEVELS + ["*"]:
		mochi.access.revoke(subject, resource, op)

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

def log_activity(object_id, user, action, field="", oldvalue="", newvalue=""):
	"""Log an activity entry for an object and replicate it to subscribers
	when this host owns the CRM. Subscribers insert the same row by UID
	so the activity table stays a converged append-only log."""
	activity_id = mochi.uid()
	now = mochi.time.now()
	mochi.db.execute(
		"insert into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
		activity_id, object_id, user, action, field, str(oldvalue), str(newvalue), now
	)
	owned = mochi.db.row(
		"select o.crm from objects o join crms c on c.id=o.crm where o.id=? and c.owner=1",
		object_id
	)
	if owned:
		broadcast_event(owned["crm"], "activity/log", {
			"crm": owned["crm"], "id": activity_id, "object": object_id,
			"user": user, "action": action, "field": field,
			"oldvalue": str(oldvalue), "newvalue": str(newvalue), "created": now,
		})

def get_owner_identity(crm_id):
	"""Get the crm owner's identity from the first subscriber."""
	row = mochi.db.row("select id from subscribers where crm=? order by subscribed limit 1", crm_id)
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
	"""Notify subscribers who are @mentioned in a comment."""
	content_lower = content.lower()
	subscribers = mochi.db.rows(
		"select id, name from subscribers where crm=? and id!=?",
		crm_id, author_id)
	if not subscribers:
		return
	mentioned = False
	for sub in subscribers:
		name = sub.get("name")
		if name and ("@[" + name + "]").lower() in content_lower:
			mentioned = True
			break
	if not mentioned:
		return
	crm = get_crm(crm_id)
	obj = mochi.db.row("select class from objects where id=?", object_id)
	if not crm or not obj:
		return
	title = get_object_display(crm, obj, object_id)
	fp = mochi.entity.fingerprint(crm_id)
	url = "/crm/" + fp + "/" + object_id if fp else "/crm"
	excerpt = content.strip()[:80]
	notify("mention", crm_id, title, mochi.app.label("notifications.body.mentioned_you", author=author_name, excerpt=excerpt), url, event_id="mention:" + object_id)

def would_create_cycle(object_id, new_parent_id):
	"""Check if setting new_parent_id as parent of object_id would create a cycle."""
	if not new_parent_id:
		return False
	current = new_parent_id
	while current:
		if current == object_id:
			return True
		parent_row = mochi.db.row("select parent from objects where id=?", current)
		current = parent_row["parent"] if parent_row else ""
	return False

def get_all_descendants(object_id, depth=0):
	"""Get all descendant object IDs recursively."""
	if depth >= 100:
		return []
	result = []
	children = mochi.db.rows("select id from objects where parent=?", object_id)
	for child in (children or []):
		result.append(child["id"])
		result.extend(get_all_descendants(child["id"], depth + 1))
	return result

def delete_object_cascade(crm_id, object_id, user=""):
	"""Delete an object and all its children recursively."""
	# First, recursively delete all children
	children = mochi.db.rows("select id from objects where parent=?", object_id)
	for child in children:
		delete_object_cascade(crm_id, child["id"], user)

	# Then delete this object's related data
	mochi.attachment.clear(object_id)
	row_remove("watchers", ["object", "user"], "object=?", [object_id])
	mochi.db.execute("delete from activity where object=?", object_id)
	delete_object_comments(object_id, crm_id)
	row_remove("values", ["object", "field"], "object=?", [object_id])
	row_remove("links", ["source", "target", "linktype"], "source=? or target=?", [object_id, object_id])
	row_remove("objects", ["id"], "id=?", [object_id])
	# Broadcast delete event for each object
	broadcast_event(crm_id, "object/delete", {"crm": crm_id, "id": object_id, "user": user})

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

	query += " order by o.rank asc, o.created desc"

	rows = mochi.db.rows(query, *params) or []

	# Batch-fetch all values for the returned objects
	values_map = {}
	if rows:
		placeholders = ",".join(["?" for _ in rows])
		object_ids = [row["id"] for row in rows]
		all_values = mochi.db.rows("select object, field, value from \"values\" where object in (" + placeholders + ")", *object_ids) or []
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

	# Look up the title field for this class
	title_field_row = mochi.db.row("select title from classes where crm=? and id=?", crm_id, obj_class)
	title_field = title_field_row["title"] if title_field_row else ""

	if crm["owner"] != 1:
		result = forward_to_owner(a, crm_id, "object/create", {
			"crm": crm_id, "class": obj_class,
			"title": title, "parent": parent,
		})
		if result and result.get("data"):
			d = result["data"]
			if d.get("id"):
				# Use the canonical rank/timestamps from the owner's response so
				# every subscriber agrees on the order. Falling back to local now()
				# only if an old owner is replying without these fields.
				now = mochi.time.now()
				rank = d.get("rank", 0)
				created = d.get("created") or now
				updated = d.get("updated") or now
				if not mochi.db.exists("select 1 from objects where id=?", d["id"]):
					row_merge("objects", ["id"], {"id": d["id"], "crm": crm_id, "class": obj_class, "parent": parent, "rank": rank, "created": created, "updated": updated})
				if title and title_field:
					row_merge("values", ["object", "field"], {"object": d["id"], "field": title_field, "value": title})
				# Auto-watch creator locally so subscriber gets notifications
				row_merge("watchers", ["object", "user"], {"object": d["id"], "user": a.user.identity.id, "created": now})
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	if len(title) > 500:
		a.error.label(400, "errors.title_too_long")
		return

	if not obj_class:
		a.error.label(400, "errors.class_is_required")
		return

	# Verify class exists
	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, obj_class)
	if not class_row:
		a.error.label(400, "errors.invalid_class")
		return

	# Check hierarchy rules
	parent_class = ""
	if parent:
		parent_row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
		if not parent_row:
			a.error.label(404, "errors.parent_object_not_found")
			return
		parent_class = parent_row["class"]
	allowed = mochi.db.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, obj_class, parent_class)
	if not allowed:
		a.error.label(400, "errors.hierarchy_disallowed")
		return

	# Calculate initial rank (add to end of parent or CRM)
	initial_rank = rank_after_all(crm_id, None)

	# Create object
	object_id = mochi.uid()
	now = mochi.time.now()

	row_merge("objects", ["id"], {"id": object_id, "crm": crm_id, "class": obj_class, "parent": parent, "rank": initial_rank, "created": now, "updated": now})

	# Set title if provided
	values = {}
	if title and title_field:
		row_merge("values", ["object", "field"], {"object": object_id, "field": title_field, "value": title})
		values[title_field] = title

	# Log activity
	log_activity(object_id, a.user.identity.id, "created")

	# Auto-watch creator
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": a.user.identity.id, "created": now})
	# Broadcast to subscribers
	broadcast_event(crm_id, "object/create", {
		"crm": crm_id, "id": object_id, "class": obj_class,
		"parent": parent, "rank": initial_rank, "values": values,
		"created": now, "updated": now, "user": a.user.identity.id
	})

	return {"data": {
		"id": object_id,
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

	crm = get_crm(crm_id)

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
		mochi.service.call("notifications", "clear/object", "crm", object_id)

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
		"comment_count": comment_count,
	}}

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
		if result and object_id:
			now = mochi.time.now()
			if a.input("parent") != None:
				row_set("objects", ["id"], "id=?", [object_id], {"parent": p, "updated": now})
			if c:
				row_set("objects", ["id"], "id=?", [object_id], {"class": c, "updated": now})
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

	now = mochi.time.now()

	# Update parent if provided
	parent = a.input("parent")
	if a.input("parent") != None:
		old_parent = row["parent"]
		if parent != old_parent:
			# Check for cycles
			if parent and would_create_cycle(object_id, parent):
				a.error.label(400, "errors.cannot_set_parent_would_create_a_cycle")
				return
			# Check hierarchy rules
			if parent:
				parent_row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
				if not parent_row:
					a.error.label(404, "errors.parent_object_not_found")
					return
				parent_class = parent_row["class"]
			else:
				parent_class = ""
			allowed = mochi.db.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, row["class"], parent_class)
			if not allowed:
				a.error.label(400, "errors.parent_hierarchy_disallowed")
				return
			row_set("objects", ["id"], "id=?", [object_id], {"parent": parent, "updated": now})
			log_activity(object_id, a.user.identity.id, "moved", "parent", old_parent, parent)

			# Sync child's column/row values to match new parent
			if parent:
				parent_values = mochi.db.rows('select field, value from "values" where object=?', parent) or []
				parent_val_map = {v["field"]: v["value"] for v in parent_values}
				views = mochi.db.rows("select columns, rows from views where crm=?", crm_id) or []
				sync_fields = {}
				for view in views:
					if view["columns"]:
						sync_fields[view["columns"]] = True
					if view["rows"]:
						sync_fields[view["rows"]] = True
				all_ids = [object_id] + get_all_descendants(object_id)
				for sync_id in all_ids:
					for field_id in sync_fields:
						parent_val = parent_val_map.get(field_id, "")
						row_merge("values", ["object", "field"], {"object": sync_id, "field": field_id, "value": parent_val})
	# Update class if provided
	new_class = a.input("class")
	if new_class and new_class != row["class"]:
		# Verify class exists
		class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, new_class)
		if class_row:
			row_set("objects", ["id"], "id=?", [object_id], {"class": new_class, "updated": now})
			log_activity(object_id, a.user.identity.id, "updated", "class", row["class"], new_class)

	row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
	broadcast_event(crm_id, "object/update", {
		"crm": crm_id, "id": object_id,
		"parent": parent if a.input("parent") != None else row["parent"],
		"class": new_class if new_class and new_class != row["class"] else row["class"],
		"user": a.user.identity.id,
		"updated": now
	})

	return {"data": {"success": True}}

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
		if result and object_id:
			row_remove("values", ["object", "field"], "object=?", [object_id])
			row_remove("watchers", ["object", "user"], "object=?", [object_id])
			delete_object_comments(object_id, crm_id)
			row_remove("links", ["source", "target", "linktype"], "source=? or target=?", [object_id, object_id])
			row_remove("objects", ["id"], "id=?", [object_id])
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

	object_id = a.input("object")

	if crm["owner"] != 1:
		params = {
			"crm": crm_id, "object": object_id,
			"field": a.input("field") or "", "value": a.input("value"),
			"rank": a.input("rank"),
		}
		rf = a.input("row_field")
		if rf:
			params["row_field"] = rf
			params["row_value"] = a.input("row_value")
		sp = a.input("scope_parent")
		if sp != None:
			params["scope_parent"] = sp
		if a.input("promote") == "true":
			params["promote"] = "true"
		result = forward_to_owner(a, crm_id, "object/move", params)
		if result and object_id:
			now = mochi.time.now()
			field = a.input("field") or ""
			value = a.input("value")
			rank = a.input("rank")
			if value:
				row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": value})
			if rank:
				old_value_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field)
				old_value = old_value_row["value"] if old_value_row else ""
				target_value = value if value else old_value
				# Fractional key between the neighbours at the drop slot (#53): one
				# write, converges under multi-master — no whole-scope renumber.
				new_key = rank_move_key(crm_id, object_id, field, target_value, sp, int(rank))
				row_set("objects", ["id"], "id=?", [object_id], {"rank": new_key, "updated": now})
			if rf:
				row_merge("values", ["object", "field"], {"object": object_id, "field": rf, "value": a.input("row_value")})
			if a.input("promote") == "true":
				row_set("objects", ["id"], "id=?", [object_id], {"parent": '', "updated": now})
			row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	if not object_id:
		a.error.label(400, "errors.object_id_required")
		return

	row = mochi.db.row("select id, class, rank from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	old_rank = row["rank"]
	obj_class = row["class"]
	field = a.input("field") or ""
	value = a.input("value")  # New column value
	new_rank = a.input("rank")

	if field and len(field) > 100:
		a.error.label(400, "errors.field_name_too_long")
		return

	if field and not mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, obj_class, field):
		a.error.label(400, "errors.field_not_found")
		return

	if value and len(str(value)) > 10000:
		a.error.label(400, "errors.value_too_long")
		return

	# Get old field value
	old_value_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field)
	old_value = old_value_row["value"] if old_value_row else ""

	# Determine target value (use provided or keep current)
	target_value = value if value else old_value
	value_changed = old_value != target_value

	# Handle field value change
	if value_changed:
		row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": target_value})
		log_activity(object_id, a.user.identity.id, "updated", field, old_value, target_value)

	# Handle rank change
	scope_parent = a.input("scope_parent")
	# Handle rank change. Fractional key between the neighbours at the drop slot
	# (#53): one write, converges under multi-master — no whole-scope renumber.
	if a.input("rank") != None:
		new_key = rank_move_key(crm_id, object_id, field, target_value, scope_parent, int(new_rank))
		row_set("objects", ["id"], "id=?", [object_id], {"rank": new_key})
	elif value_changed:
		# Moving to a new column without a specific rank — append to its end.
		# Anchor on the crm-wide max for a globally-unique key (see rank_after_all);
		# crm-max >= the column's last, so it still lands last.
		new_key = rank_after_all(crm_id, object_id)
		row_set("objects", ["id"], "id=?", [object_id], {"rank": new_key})
	# Handle row field change (for swimlane drag-drop)
	row_field = a.input("row_field")
	row_value = a.input("row_value")
	if row_field and len(row_field) > 100:
		a.error.label(400, "errors.field_name_too_long")
		return
	if row_field and not mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, obj_class, row_field):
		a.error.label(400, "errors.field_not_found")
		return
	if row_value and len(str(row_value)) > 10000:
		a.error.label(400, "errors.value_too_long")
		return
	row_changed = False
	if row_field:
		old_row_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, row_field)
		old_row_value = old_row_row["value"] if old_row_row else ""
		if old_row_value != row_value:
			row_merge("values", ["object", "field"], {"object": object_id, "field": row_field, "value": row_value})
			log_activity(object_id, a.user.identity.id, "updated", row_field, old_row_value, row_value)
			row_changed = True

	# Handle promote (clear parent — for child dragged to different column/row)
	promote = a.input("promote") == "true"
	if promote:
		old_parent_row = mochi.db.row("select parent from objects where id=?", object_id)
		old_parent = old_parent_row["parent"] if old_parent_row else ""
		if old_parent:
			row_set("objects", ["id"], "id=?", [object_id], {"parent": '', "updated": mochi.time.now()})
			log_activity(object_id, a.user.identity.id, "moved", "parent", old_parent, "")

	row_set("objects", ["id"], "id=?", [object_id], {"updated": mochi.time.now()})
	# Cascade status/row changes to all descendants
	if value_changed or row_changed:
		descendants = get_all_descendants(object_id)
		now = mochi.time.now()
		for desc_id in descendants:
			if value_changed:
				row_merge("values", ["object", "field"], {"object": desc_id, "field": field, "value": target_value})
			if row_changed:
				row_merge("values", ["object", "field"], {"object": desc_id, "field": row_field, "value": row_value})
			row_set("objects", ["id"], "id=?", [desc_id], {"updated": now})
	updated_values = {}
	if value_changed:
		updated_values[field] = target_value
	if row_changed:
		updated_values[row_field] = row_value
	if updated_values:
		broadcast_event(crm_id, "values/update", {
			"crm": crm_id, "id": object_id,
			"values": updated_values, "user": a.user.identity.id
		})

	# Only the moved object's fractional key changed (#53), so broadcast just that
	# one row — no whole-scope read, no N-row replication. event_object_ranks
	# applies each entry by id, so a single-element list converges everywhere.
	if a.input("rank") != None:
		moved = mochi.db.row("select rank from objects where id=? and crm=?", object_id, crm_id)
		if moved:
			broadcast_event(crm_id, "object/ranks", {
				"crm": crm_id,
				"ranks": [{"id": object_id, "rank": moved["rank"]}],
				"user": a.user.identity.id,
			})

	return {"data": {"success": True}}

# ============================================================================
# Value Actions
# ============================================================================

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
		values = {}
		for field_id in valid_fields:
			if a.input(field_id) != None:
				values[field_id] = str(a.input(field_id))
		result = forward_to_owner(a, crm_id, "values/set", {
			"crm": crm_id, "object": object_id, "values": values,
		})
		if result:
			for field_id, value in values.items():
				row_merge("values", ["object", "field"], {"object": object_id, "field": field_id, "value": value})
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error.label(403, "errors.access_denied")
		return

	now = mochi.time.now()
	changes = []

	# Process each field from input
	for field_id in valid_fields:
		if a.input(field_id) == None:
			continue
		new_value = a.input(field_id)
		if len(str(new_value)) > 10000:
			a.error.label(400, "errors.value_too_long")
			return
		invalid = validate_field_value(crm_id, row["class"], field_id, new_value)
		if invalid:
			a.error.label(400, invalid["key"], **(invalid.get("args") or {}))
			return
		# Get old value
		old_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field_id)
		old_value = old_row["value"] if old_row else ""

		if str(new_value) != old_value:
			row_merge("values", ["object", "field"], {"object": object_id, "field": field_id, "value": str(new_value)})
			log_activity(object_id, a.user.identity.id, "updated", field_id, old_value, str(new_value))
			changes.append(field_id)

	if changes:
		row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
		# Collect changed values for broadcast
		changed_values = {}
		for fid in changes:
			val = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, fid)
			if val:
				changed_values[fid] = val["value"]
		broadcast_event(crm_id, "values/update", {
			"crm": crm_id, "id": object_id, "values": changed_values,
			"user": a.user.identity.id
		})
		# Auto-watch assigned users
		for fid in changes:
			if field_types.get(fid) == "user":
				assigned = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, fid)
				if assigned and assigned["value"]:
					row_merge("watchers", ["object", "user"], {"object": object_id, "user": assigned["value"], "created": now})

	return {"data": {"success": True, "changed": changes}}

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
		if result:
			# Update local cache so subsequent reads reflect the change
			row_merge("values", ["object", "field"], {"object": a.input("object"), "field": a.input("field"), "value": a.input("value") or ""})
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
	if len(new_value) > 10000:
		a.error.label(400, "errors.value_too_long")
		return

	invalid = validate_field_value(crm_id, row["class"], field_id, new_value)
	if invalid:
		a.error.label(400, invalid["key"], **(invalid.get("args") or {}))
		return

	# Get old value
	old_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field_id)
	old_value = old_row["value"] if old_row else ""

	if str(new_value) != old_value:
		row_merge("values", ["object", "field"], {"object": object_id, "field": field_id, "value": str(new_value)})
		now = mochi.time.now()
		row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
		log_activity(object_id, a.user.identity.id, "updated", field_id, old_value, str(new_value))
		broadcast_event(crm_id, "values/update", {
			"crm": crm_id, "id": object_id,
			"values": {field_id: str(new_value)}, "user": a.user.identity.id
		})
		# Auto-watch assigned user
		if field_row["fieldtype"] == "user" and str(new_value):
			row_merge("watchers", ["object", "user"], {"object": object_id, "user": str(new_value), "created": now})

	return {"data": {"success": True}}

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
		left join "values" v on v.object = l.target and v.field = 'title'
		where l.source=?
	""", object_id) or []

	# Get incoming links
	incoming = mochi.db.rows("""
		select l.source, l.linktype, l.created, o.class, v.value as title
		from links l
		join objects o on o.id = l.source
		left join "values" v on v.object = l.source and v.field = 'title'
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

	row_remove("links", ["source", "target", "linktype"], "crm=? and source=? and target=? and linktype=?", [crm_id, object_id, target_id, linktype])
	broadcast_event(crm_id, "link/delete", {
		"crm": crm_id, "source": object_id,
		"target": target_id, "linktype": linktype, "user": a.user.identity.id
	})

	return {"data": {"success": True}}

# Build a recursive comment tree for an object
def object_comments(crm_id, object_id, parent_id, depth):
	if depth > 100:
		return []
	comments = mochi.db.rows(
		"select id, parent, author, name, content, created, edited from comments where object=? and parent=? order by created desc",
		object_id, parent_id
	) or []
	for i in range(len(comments)):
		comments[i]["children"] = object_comments(crm_id, object_id, comments[i]["id"], depth + 1)
		comments[i]["attachments"] = mochi.attachment.list(comments[i]["id"], crm_id) or []
	return comments

# Recursively delete a comment and all its children and attachments
def delete_comment_tree(comment_id, crm_id):
	children = mochi.db.rows("select id from comments where parent=?", comment_id) or []
	for child in children:
		delete_comment_tree(child["id"], crm_id)
	for att in (mochi.attachment.list(comment_id, crm_id) or []):
		mochi.attachment.delete(att["id"])
	row_remove("comments", ["id"], "id=?", [comment_id])
# Delete all comments and their attachments for an object
def delete_object_comments(object_id, crm_id):
	comments = mochi.db.rows("select id from comments where object=?", object_id) or []
	for c in comments:
		for att in (mochi.attachment.list(c["id"], crm_id) or []):
			mochi.attachment.delete(att["id"])
	row_remove("comments", ["id"], "object=?", [object_id])
# Delete all comment attachments for all objects in a crm
def delete_crm_comment_attachments(crm_id):
	comments = mochi.db.rows(
		"select c.id from comments c join objects o on c.object=o.id where o.crm=?", crm_id
	) or []
	for c in comments:
		for att in (mochi.attachment.list(c["id"], crm_id) or []):
			mochi.attachment.delete(att["id"])

# ============================================================================
# Person asset proxy (avatar, banner, favicon, style, information)
# ============================================================================

# Stream an entity's asset from its owning service via a Mochi stream.
# Location-transparent: mochi.remote.stream() loops back in-process when the
# entity lives on this server, or goes over P2P otherwise.
def stream_asset(a, entity_id, service, asset):
	if not entity_id:
		a.error.label(404, "errors.asset_unavailable", asset=asset)
		return None
	s = mochi.remote.stream(entity_id, service, asset, {})
	if not s:
		a.error.label(404, "errors.asset_unavailable", asset=asset)
		return None
	header = s.read()
	if not header or header.get("status") != "200":
		a.error.label(404, "errors.asset_not_set", asset=asset)
		return None
	a.header("Cache-Control", "private, max-age=300")
	if "data" in header:
		return {"data": header["data"]}
	a.header("Content-Type", header.get("content_type", "application/octet-stream"))
	a.write.stream(s)
	return None

_PERSON_ASSETS = ("avatar", "banner", "favicon", "style", "information")

def action_comment_asset(a):
	asset = a.input("asset")
	if asset not in _PERSON_ASSETS:
		a.error.label(404, "errors.unknown_asset")
		return
	row = mochi.db.row("select author from comments where id=?", a.input("comment"))
	return stream_asset(a, row["author"] if row else "", "people", asset)

def action_activity_asset(a):
	asset = a.input("asset")
	if asset not in _PERSON_ASSETS:
		a.error.label(404, "errors.unknown_asset")
		return
	row = mochi.db.row("select user from activity where id=?", a.input("activity"))
	return stream_asset(a, row["user"] if row else "", "people", asset)

def action_user_asset(a):
	asset = a.input("asset")
	if asset not in _PERSON_ASSETS:
		a.error.label(404, "errors.unknown_asset")
		return
	return stream_asset(a, a.input("user") or "", "people", asset)

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
		attachments = mochi.attachment.save(comment_id, "files", [], [], [])
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
			"children": [], "attachments": mochi.attachment.list(comment_id, crm_id) or [],
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

	attachments = mochi.attachment.save(comment_id, "files", [], [], []) or []

	row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
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
	row_set("comments", ["id"], "id=?", [comment_id], {"content": content.strip(), "edited": now})
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
			# The owner has no such comment. If a local copy authored by this
			# user exists, it is a phantom — an optimistic write whose submit
			# never reached the owner — and no remote delete can ever succeed,
			# so clean it up locally instead of leaving it stuck forever
			# (#466, mirrors projects). The local tombstone replicates only to
			# this user's own hosts, where the phantom lives.
			comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
			if comment and comment["author"] == a.user.identity.id:
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

# HTTP handlers serving a CRM's attachments (and thumbnails). Auth-only routes.
# Core's a.write.attachment serves the bytes with no access check of its own, so
# this handler is the gate: require_crm enforces CRM view access (for CRMs we
# own), and the attachment must belong to an object or comment in THIS CRM, so
# one CRM's attachment can't be fetched via another CRM's route.
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
	if crm["owner"] == 1:
		# We own this CRM: require_crm enforced view access. Bind the attachment
		# to an object or a comment (comment -> object -> crm) in this CRM.
		att = mochi.attachment.get(attachment)
		if not att:
			a.error.label(404, "errors.attachment_not_found")
			return
		obj = att.get("object")
		in_crm = mochi.db.exists("select 1 from objects where id=? and crm=?", obj, crm_id)
		if not in_crm:
			in_crm = mochi.db.exists("select 1 from comments c join objects o on o.id=c.object where c.id=? and o.crm=?", obj, crm_id)
		if not in_crm:
			a.error.label(404, "errors.attachment_not_found")
			return
	# Remote CRM (owner != 1): the owning server enforces access and the binding
	# when a.write.attachment fetches over P2P; per-user databases isolate one
	# subscriber from another.
	a.write.attachment(attachment, variant=variant)

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

	attachments = mochi.attachment.list(object_id, crm_id) or []

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
		attachments = mochi.attachment.save(object_id, "files", [], [], []) or []
		if not attachments:
			a.error.label(400, "errors.file_is_required")
			return
		# Fire-and-forget to crm owner with attachment metadata
		submit_data = {"object": object_id, "names": [att["name"] for att in attachments]}
		submit_data["attachments"] = [{"id": att["id"], "name": att["name"], "size": att["size"], "content_type": att.get("type", ""), "rank": att.get("rank", 0), "created": att.get("created", 0)} for att in attachments]
		mochi.message.send(
			{"from": a.user.identity.id, "to": crm_id, "service": "crm", "event": "attachment/submit"},
			submit_data
		)
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
	attachments = mochi.attachment.save(object_id, "files", [], [], []) or []

	if not attachments:
		a.error.label(400, "errors.file_is_required")
		return

	row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
	for att in attachments:
		log_activity(object_id, a.user.identity.id, "attached", "", "", att["name"])

	# Broadcast attachment metadata to subscribers
	broadcast_event(crm_id, "attachment/add", {
		"crm": crm_id, "object": object_id,
		"attachments": [{"id": att["id"], "name": att["name"], "size": att["size"], "content_type": att.get("type", ""), "rank": att.get("rank", 0), "created": att.get("created", now)} for att in attachments]
	})

	return {"data": {"attachments": attachments}}

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

	if not mochi.attachment.exists(attachment_id):
		a.error.label(404, "errors.attachment_not_found")
		return

	mochi.attachment.delete(attachment_id, [])

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

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error.label(404, "errors.object_not_found")
		return

	limit = safe_int(a.input("limit"), 100)
	offset = safe_int(a.input("offset"))
	if limit < 1 or limit > 500:
		limit = 100

	rows = mochi.db.rows(
		"select id, user, action, field, oldvalue, newvalue, created from activity where object=? order by created desc limit ? offset ?",
		object_id, limit, offset
	) or []

	# Resolve user names
	activities = []
	for row in rows:
		user = row["user"]
		name = mochi.entity.name(user) or user[:9]
		activities.append({
			"id": row["id"],
			"user": user,
			"name": name,
			"action": row["action"],
			"field": row["field"],
			"oldvalue": row["oldvalue"],
			"newvalue": row["newvalue"],
			"created": row["created"],
		})

	return {"data": {"activities": activities}}

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
	row_remove("watchers", ["object", "user"], "object=? and user=?", [object_id, a.user.identity.id])
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
			"fields": a.input("fields") or "title,priority,owner,due",
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

	viewtype = a.input("viewtype") or "board"
	if viewtype not in ["board", "list"]:
		a.error.label(400, "errors.invalid_view_type")
		return

	# Generate view ID from name
	view_id = name.strip().lower().replace(" ", "_")

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
	fields = a.input("fields") or "title,priority,owner,due"
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
	view_classes = a.input("classes") or ""
	if view_classes:
		for cls_id in [c.strip() for c in view_classes.split(",") if c.strip()]:
			row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": cls_id})

	broadcast_event(crm_id, "view/create", {
		"crm": crm_id, "id": view_id, "name": name.strip(),
		"viewtype": viewtype, "filter": filter_str, "columns": columns,
		"rows": rows, "fields": fields, "sort": sort, "direction": direction,
		"border": border
	})

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
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"name": name.strip()})
	if a.input("viewtype") != None and viewtype != "":
		if viewtype not in ["board", "list"]:
			a.error.label(400, "errors.invalid_view_type")
			return
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"viewtype": viewtype})
	if a.input("filter") != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"filter": filter_str})
	if a.input("columns") != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"columns": columns})
	if a.input("rows") != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"rows": rows})
	if a.input("fields") != None:
		# Delete existing fields and insert new ones
		row_remove("view_fields", ["crm", "view", "field"], "crm=? and view=?", [crm_id, view_id])
		for i, field in enumerate(fields.split(",")):
			if field.strip():
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field.strip(), "rank": i})
	if a.input("sort") != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"sort": sort})
	if a.input("direction") != None and direction != "":
		if direction not in ["asc", "desc"]:
			a.error.label(400, "errors.invalid_direction")
			return
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"direction": direction})
	border = a.input("border")
	if a.input("border") != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"border": border})
	# Update view classes if provided (comma-separated list of class IDs, empty string = all classes)
	view_classes_input = a.input("classes")
	if a.input("classes") != None:
		# Delete existing view classes
		row_remove("view_classes", ["crm", "view", "class"], "crm=? and view=?", [crm_id, view_id])
		# Insert new view classes
		if view_classes_input:
			cls_ids = [c.strip() for c in view_classes_input.split(",") if c.strip()]
			for cls_id in cls_ids:
				row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": cls_id})

	# Read back updated view for broadcast
	updated = mochi.db.row("select * from views where crm=? and id=?", crm_id, view_id)
	if updated:
		# Get fields from junction table
		view_fields = mochi.db.rows("select field from view_fields where crm=? and view=? order by rank", crm_id, view_id) or []
		updated_fields = ",".join([vf["field"] for vf in view_fields])
		broadcast_event(crm_id, "view/update", {
			"crm": crm_id, "id": view_id,
			"name": updated["name"], "viewtype": updated["viewtype"],
			"filter": updated["filter"], "columns": updated["columns"],
			"rows": updated["rows"], "fields": updated_fields,
			"sort": updated["sort"], "direction": updated["direction"],
			"rank": updated["rank"], "border": updated["border"]
		})

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

	row_remove("view_fields", ["crm", "view", "field"], "crm=? and view=?", [crm_id, view_id])
	row_remove("view_classes", ["crm", "view", "class"], "crm=? and view=?", [crm_id, view_id])
	row_remove("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id])
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
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"rank": i})

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
	class_id = name.strip().lower().replace(" ", "_")

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
	row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": class_id, "id": "title", "name": "Title", "fieldtype": "text", "flags": "required,sort", "rank": 0})

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
		t = a.input("title")
		if t:
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
	if name:
		row_set("classes", ["crm", "id"], "crm=? and id=?", [crm_id, class_id], {"name": name.strip()})
	title_input = a.input("title")
	if title_input:
		row_set("classes", ["crm", "id"], "crm=? and id=?", [crm_id, class_id], {"title": title_input})
	broadcast_event(crm_id, "class/update", {
		"crm": crm_id, "id": class_id, "name": name or class_row["name"],
		"title": title_input or class_row["title"]
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
	row_remove("options", ["crm", "class", "field", "id"], "crm=? and class=?", [crm_id, class_id])
	row_remove("fields", ["crm", "class", "id"], "crm=? and class=?", [crm_id, class_id])
	row_remove("view_classes", ["crm", "view", "class"], "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and parent=?", [crm_id, class_id])
	row_remove("classes", ["crm", "id"], "crm=? and id=?", [crm_id, class_id])
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
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and class=?", [crm_id, class_id])
	# Insert new hierarchy entries
	for parent in parents:
		# Verify parent class exists (unless it's empty string for root)
		if parent and parent != "":
			parent_exists = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, parent)
			if not parent_exists:
				continue  # Skip invalid parents
		row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": class_id, "parent": parent})

	broadcast_event(crm_id, "hierarchy/set", {
		"crm": crm_id, "class": class_id, "parents": parents
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
	if fieldtype not in ["text", "number", "date", "enumerated", "user", "object", "checkbox", "checklist"]:
		a.error.label(400, "errors.invalid_field_type")
		return

	# Generate field ID from name
	field_id = name.strip().lower().replace(" ", "_")

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
		for k in ["name", "flags", "multi", "card", "position", "rows", "id"]:
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

	if a.input("name") != None:
		name = a.input("name").strip()
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"name": name})
		update_data["name"] = name
	if a.input("flags") != None:
		flags = a.input("flags")
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"flags": flags})
		update_data["flags"] = flags
	if a.input("multi") != None:
		multi_val = 1 if a.input("multi") in ("1", "true") else 0
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"multi": multi_val})
		update_data["multi"] = multi_val
	if a.input("card") != None:
		card_val = 1 if a.input("card") in ("1", "true") else 0
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"card": card_val})
		update_data["card"] = card_val
	if a.input("min") != None:
		min_val = a.input("min")
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"min": min_val})
		update_data["min"] = min_val
	if a.input("max") != None:
		max_val = a.input("max")
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"max": max_val})
		update_data["max"] = max_val
	if a.input("pattern") != None:
		pattern = a.input("pattern")
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"pattern": pattern})
		update_data["pattern"] = pattern
	if a.input("minlength") != None:
		minlength = safe_int(a.input("minlength"))
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"minlength": minlength})
		update_data["minlength"] = minlength
	if a.input("maxlength") != None:
		maxlength = safe_int(a.input("maxlength"))
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"maxlength": maxlength})
		update_data["maxlength"] = maxlength
	if a.input("prefix") != None:
		prefix = a.input("prefix")
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"prefix": prefix})
		update_data["prefix"] = prefix
	if a.input("suffix") != None:
		suffix = a.input("suffix")
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"suffix": suffix})
		update_data["suffix"] = suffix
	if a.input("format") != None:
		format_str = a.input("format")
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"format": format_str})
		update_data["format"] = format_str
	if a.input("position") != None:
		position = a.input("position")
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"position": position})
		update_data["position"] = position
	if a.input("rows") != None:
		rows_val = safe_int(a.input("rows"), 1)
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rows": rows_val})
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
			update_data["old_id"] = field_id
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

	# Delete options for this field
	row_remove("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=?", [crm_id, class_id, field_id])
	# Delete field
	row_remove("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id])
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
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rank": i})

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
	option_id = name.strip().lower().replace(" ", "_")

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
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"name": name.strip()})
	if a.input("colour") != None:
		if len(colour) > 20:
			a.error.label(400, "errors.colour_too_long")
			return
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"colour": colour})
	if a.input("icon") != None:
		if len(icon) > 100:
			a.error.label(400, "errors.icon_too_long")
			return
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"icon": icon})
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

	row_remove("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id])
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
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"rank": i})

	broadcast_event(crm_id, "option/reorder", {"crm": crm_id, "class": class_id, "field": field_id, "order": order})

	return {"data": {"success": True}}

# Search for crms in the directory
def action_search(a):

	search = a.input("search")
	if not search:
		a.error.label(400, "errors.no_search_entered")
		return
	if len(search) > 500:
		a.error.label(400, "errors.search_query_too_long")
		return

	results = []
	all_crms = None

	# Check if search term is an entity ID (49-51 word characters)
	if mochi.text.valid(search, "entity"):
		entry = mochi.directory.get(search)
		if entry and entry.get("class") == "crm":
			results.append(entry)

	# Check if search term is a fingerprint (9 alphanumeric, with or without hyphens)
	fingerprint = search.replace("-", "")
	if mochi.text.valid(fingerprint, "fingerprint"):
		matches = mochi.directory.search("crm", "", False, fingerprint=fingerprint)
		for entry in matches:
			found = False
			for r in results:
				if r.get("id") == entry.get("id"):
					found = True
					break
			if not found:
				results.append(entry)

	# Check if search term is a URL (e.g., https://example.com/crm/ENTITY_ID)
	if search.startswith("http://") or search.startswith("https://"):
		url = search
		if "/crm/" in url:
			parts = url.split("/crm/", 1)
			server = parts[0]
			crm_path = parts[1]
			# Handle query parameter format: ?crm=ENTITY_ID
			if crm_path.startswith("?crm="):
				crm_id = crm_path[9:]
				if "&" in crm_id:
					crm_id = crm_id.split("&")[0]
				if "#" in crm_id:
					crm_id = crm_id.split("#")[0]
			else:
				# Path format: /crm/ENTITY_ID or /crm/ENTITY_ID/...
				crm_id = crm_path.split("/")[0] if "/" in crm_path else crm_path
				if "?" in crm_id:
					crm_id = crm_id.split("?")[0]
				if "#" in crm_id:
					crm_id = crm_id.split("#")[0]

			if mochi.text.valid(crm_id, "entity"):
				entry = mochi.directory.get(crm_id)
				if entry and entry.get("class") == "crm":
					# Avoid duplicates
					found = False
					for r in results:
						if r.get("id") == entry.get("id"):
							found = True
							break
					if not found:
						results.append(entry)
				elif not results:
					# Not in directory — probe remote server via P2P
					peer = mochi.remote.peer(server)
					if peer:
						response = mochi.remote.request(crm_id, "crm", "info", {"crm": crm_id}, peer)
						if not response.get("error"):
							results.append({
								"id": response.get("id", crm_id),
								"name": response.get("name", ""),
								"fingerprint": response.get("fingerprint", ""),
								"class": "crm",
								"location": server,
							})

			# Try as fingerprint — check local directory first, then probe remote
			elif mochi.text.valid(crm_id, "fingerprint"):
				if all_crms == None:
					all_crms = mochi.directory.search("crm", "", False)
				for entry in all_crms:
					entry_fp = entry.get("fingerprint", "").replace("-", "")
					if entry_fp == crm_id.replace("-", ""):
						found = False
						for r in results:
							if r.get("id") == entry.get("id"):
								found = True
								break
						if not found:
							results.append(entry)
						break
				if not results:
					# Not in directory — probe remote server via P2P
					peer = mochi.remote.peer(server)
					if peer:
						response = mochi.remote.request(crm_id, "crm", "info", {"crm": crm_id}, peer)
						if not response.get("error"):
							results.append({
								"id": response.get("id", crm_id),
								"name": response.get("name", ""),
								"fingerprint": response.get("fingerprint", ""),
								"class": "crm",
								"location": server,
							})

	# Also search by name
	name_results = mochi.directory.search("crm", search, False)
	for entry in name_results:
		# Avoid duplicates
		found = False
		for r in results:
			if r.get("id") == entry.get("id"):
				found = True
				break
		if not found:
			results.append(entry)

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

	# mochi://<peer>/<entity> - a share link pins the owner's peer directly,
	# so a private CRM (never directory-listed) resolves without a hostname.
	if url.startswith("mochi://"):
		rest = url[len("mochi://"):]
		if "/" not in rest:
			a.error.label(400, "errors.invalid_data")
			return
		link_peer, path = rest.split("/", 1)
		link_crm = path.split("/")[0]
		if not link_peer or not mochi.text.valid(link_crm, "entity"):
			a.error.label(400, "errors.invalid_data")
			return
		response = mochi.remote.request(link_crm, "crm", "info", {"crm": link_crm}, link_peer)
		if response.get("error"):
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

	# Parse URL to extract server and crm ID
	# Expected formats:
	#   https://example.com/crm/ENTITY_ID
	#   http://example.com/crm/ENTITY_ID
	#   example.com/crm/ENTITY_ID
	server = ""
	crm_id = ""
	protocol = "https://"

	# Extract and preserve protocol prefix
	if url.startswith("https://"):
		protocol = "https://"
		url = url[8:]
	elif url.startswith("http://"):
		protocol = "http://"
		url = url[7:]

	# Split by /crm/ to get server and crm ID
	if "/crm/" in url:
		parts = url.split("/crm/", 1)
		server = protocol + parts[0]
		# CRM ID is everything after /crm/ up to next / or end
		crm_path = parts[1]
		if "/" in crm_path:
			crm_id = crm_path.split("/")[0]
		else:
			crm_id = crm_path
	else:
		a.error.label(400, "errors.invalid_url_format_expected_https_server_crm_crm_id")
		return

	if not server or server == protocol:
		a.error.label(400, "errors.invalid_url")
		return

	if not crm_id or (not mochi.text.valid(crm_id, "entity") and not mochi.text.valid(crm_id, "fingerprint")):
		a.error.label(400, "errors.could_not_extract_valid_crm_id_from_url")
		return

	peer = mochi.remote.peer(server)
	if not peer:
		a.error.label(502, "errors.unable_to_connect_to_server")
		return
	response = mochi.remote.request(crm_id, "crm", "info", {"crm": crm_id}, peer)
	if response.get("error"):
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

	# Connect to recommendations service
	s = mochi.remote.stream("1JYmMpQU7fxvTrwHpNpiwKCgUg3odWqX7s9t1cLswSMAro5M2P", "recommendations", "list", {"type": "crm", "language": "en"})
	if not s:
		return {"data": {"crms": []}}

	r = s.read()
	if r.get("status") != "200":
		return {"data": {"crms": []}}

	recommendations = []
	items = s.read()
	if type(items) not in ["list", "tuple"]:
		return {"data": {"crms": []}}

	# Get the server location from the recommendations entity so subscribers can reach the CRMs
	rec_dir = mochi.directory.get("1JYmMpQU7fxvTrwHpNpiwKCgUg3odWqX7s9t1cLswSMAro5M2P")
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

	crm_id = a.input("crm")
	server = a.input("server")
	peer = a.input("peer")  # from a mochi://<peer>/<crm> share link
	if not mochi.text.valid(crm_id, "entity"):
		a.error.label(400, "errors.invalid_crm_id")
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
		response = mochi.remote.request(crm_id, "crm", "info", {"crm": crm_id}, peer)
		if response.get("error"):
			remote_error(a, response, 404)
			return
		crm_name = response.get("name", "")
		crm_desc = response.get("description", "")
		# Fetch schema so it is available before the frontend navigates
		schema = mochi.remote.request(crm_id, "crm", "schema", {}, peer)
	else:
		# Use directory lookup when no server specified
		directory = mochi.directory.get(crm_id)
		if directory == None or len(directory) == 0:
			a.error.label(404, "errors.unable_to_find_crm_in_directory")
			return
		crm_name = directory.get("name", "")
		crm_desc = ""
		server = directory.get("location", "")
		# Fetch full info and schema from the resolved server
		if server:
			peer = mochi.remote.peer(server)
			if peer:
				response = mochi.remote.request(crm_id, "crm", "info", {"crm": crm_id}, peer)
				if response and not response.get("error"):
					crm_name = response.get("name", crm_name)
					crm_desc = response.get("description", "")
				schema = mochi.remote.request(crm_id, "crm", "schema", {}, peer)

	now = mochi.time.now()
	fp = mochi.entity.fingerprint(crm_id) or ""

	# Insert the remote crm. populated=0: the schema is fetched synchronously
	# below, but the bulk object data arrives asynchronously via the owner's
	# sync/batch. The board shows a loading state until event_sync_batch flips
	# this to 1.
	row_merge("crms", ["id"], {"id": crm_id, "name": crm_name, "description": crm_desc, "owner": 0, "server": server or "", "fingerprint": fp, "created": now, "updated": now, "populated": 0})

	# Insert schema so the crm page has content immediately
	if schema and not schema.get("error"):
		insert_schema(crm_id, schema)

	# Send P2P subscribe message to crm owner. A private CRM is not in the
	# directory, so when the subscription came via a share link, pin that peer.
	if peer:
		mochi.message.send.peer(peer, p2p_headers(user_id, crm_id, "subscribe"), {"name": a.user.identity.name})
	else:
		mochi.message.send(p2p_headers(user_id, crm_id, "subscribe"), {"name": a.user.identity.name})
	mochi.broadcast.touch(crm_id)

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
	delete_crm_comment_attachments(crm_id)
	purge_crm(crm_id)
	# Send P2P unsubscribe message
	mochi.message.send(p2p_headers(user_id, crm_id, "unsubscribe"), {})

	return {"data": {"success": True}}

# ============================================================================
# P2P Events
# ============================================================================

# Handle crm info request from a remote server
def event_info(e):
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
def event_schema(e):
	crm_id = e.header("to")
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

	# Classes
	classes = mochi.db.rows("select id, name, rank, title from classes where crm=?", crm_id) or []

	# Fields — batch fetch, already include class column
	fields = mochi.db.rows("select class, id, name, fieldtype, flags, multi, rank, card, position, rows from fields where crm=? order by class, rank", crm_id) or []

	# Options — batch fetch, already include class and field columns
	options = mochi.db.rows("select class, field, id, name, colour, icon, rank from options where crm=? order by class, field, rank", crm_id) or []

	# Hierarchy — batch fetch, group by class
	hierarchy = []
	all_hierarchy = mochi.db.rows("select class, parent from hierarchy where crm=?", crm_id) or []
	hierarchy_map = {}
	for h in all_hierarchy:
		hierarchy_map.setdefault(h["class"], []).append(h["parent"])
	for cls, parents in hierarchy_map.items():
		hierarchy.append({"class": cls, "parents": parents})

	# Views — batch fetch view classes and fields
	views = mochi.db.rows("select id, name, viewtype, filter, columns, rows, sort, direction, rank, border from views where crm=? order by rank, name", crm_id) or []
	all_view_fields = mochi.db.rows("select view, field from view_fields where crm=? order by rank", crm_id) or []
	vf_map = {}
	for vf in all_view_fields:
		vf_map.setdefault(vf["view"], []).append(vf["field"])
	all_view_classes = mochi.db.rows("select view, class from view_classes where crm=?", crm_id) or []
	vc_map = {}
	for vc in all_view_classes:
		vc_map.setdefault(vc["view"], []).append(vc["class"])
	for v in views:
		v["fields"] = ",".join(vf_map.get(v["id"], []))
		v["classes"] = ",".join(vc_map.get(v["id"], []))

	# Objects — batch fetch all, then batch fetch values and comments
	all_objects = mochi.db.rows("select id, class, parent, rank, created, updated from objects where crm=?", crm_id) or []
	object_ids = [obj["id"] for obj in all_objects]

	values_map = {}
	if object_ids:
		placeholders = ",".join(["?" for _ in object_ids])
		all_values = mochi.db.rows("select object, field, value from \"values\" where object in (" + placeholders + ")", *object_ids) or []
		for v in all_values:
			values_map.setdefault(v["object"], {})[v["field"]] = v["value"]

	comments_map = {}
	if object_ids:
		placeholders = ",".join(["?" for _ in object_ids])
		all_comments = mochi.db.rows("select object, id, parent, author, name, content, created, edited from comments where object in (" + placeholders + ") order by created", *object_ids) or []
		for c in all_comments:
			comments_map.setdefault(c["object"], []).append(c)

	activity_map = {}
	if object_ids:
		placeholders = ",".join(["?" for _ in object_ids])
		all_activity = mochi.db.rows("select object, id, user, action, field, oldvalue, newvalue, created from activity where object in (" + placeholders + ") order by created", *object_ids) or []
		for a in all_activity:
			activity_map.setdefault(a["object"], []).append(a)

	objects = []
	for obj in all_objects:
		if obj["id"] in values_map:
			obj["values"] = values_map[obj["id"]]
		if obj["id"] in comments_map:
			# Attach per-comment attachment metadata before nesting.
			for c in comments_map[obj["id"]]:
				c_atts = mochi.attachment.list(c["id"])
				if c_atts:
					c["attachments"] = c_atts
			obj["comments"] = comments_map[obj["id"]]
		if obj["id"] in activity_map:
			obj["activity"] = activity_map[obj["id"]]
		# Inline object-level attachment metadata so subscribers don't have to
		# rely on real-time events arriving after the initial schema dump.
		obj_atts = mochi.attachment.list(obj["id"])
		if obj_atts:
			obj["attachments"] = obj_atts
		objects.append(obj)

	# Links
	links = mochi.db.rows("select l.source, l.target, l.linktype from links l join objects o on l.source = o.id where o.crm=?", crm_id) or []

	e.stream.write({
		# CRM row first so subscribers can reconcile metadata
		# (name / description) on resync without waiting for a
		# crm/update broadcast that might never come.
		"crm": {
			"name": crm.get("name", ""),
			"description": crm.get("description", ""),
		},
		"classes": classes,
		"fields": fields,
		"options": options,
		"hierarchy": hierarchy,
		"views": views,
		"objects": objects,
		"links": links,
	})

# Insert crm schema and objects into local database.
#
# Pre-task-#86-port every insert was `insert or ignore`, so a resync
# only filled GAPS in the subscriber's local state - renames, reorders,
# edited comments, changed view configurations all stayed at their old
# values until manually fixed. This converts to UPSERTs that update the
# editable columns in place; primary-key identity stays stable so child
# FKs (fields->classes, options->fields, etc.) are never broken by a
# delete-then-insert.
#
# Append-only tables (activity) and natural-key tables that have no
# editable columns once created (links, view_classes, hierarchy) stay
# as `insert or ignore` - the row's existence IS the data; there's
# nothing to reconcile.
def insert_schema(crm_id, schema):
	# Reconcile the crm row itself (name / description). UPDATE only -
	# the crm row was created at subscribe time and we never want to
	# flip owner away from 0 on a resync. Idempotent when the
	# subscriber's row already matches.
	crm_data = schema.get("crm")
	if crm_data:
		row_set("crms", ["id"], "id=? and owner=0", [crm_id], {"name": crm_data.get("name", ""), "description": crm_data.get("description", "")})
	for c in (schema.get("classes") or []):
		row_merge("classes", ["crm", "id"], {"id": c.get("id", ""), "crm": crm_id, "name": c.get("name", ""), "rank": c.get("rank", 0), "title": c.get("title", "")})
	for f in (schema.get("fields") or []):
		row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": f.get("class", ""), "id": f.get("id", ""), "name": f.get("name", ""), "fieldtype": f.get("fieldtype", "text"), "flags": f.get("flags", ""), "multi": f.get("multi", 0), "rank": f.get("rank", 0), "card": f.get("card", 1), "position": f.get("position", ""), "rows": f.get("rows", 1)})
	for o in (schema.get("options") or []):
		row_merge("options", ["crm", "class", "field", "id"], {"crm": crm_id, "class": o.get("class", ""), "field": o.get("field", ""), "id": o.get("id", ""), "name": o.get("name", ""), "colour": o.get("colour", "#94a3b8"), "icon": o.get("icon", ""), "rank": o.get("rank", 0)})
	for h in (schema.get("hierarchy") or []):
		for parent in (h.get("parents") or []):
			# (crm, class, parent) is the full primary key; there is
			# no editable payload to reconcile, so ignore is right.
			row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": h.get("class", ""), "parent": parent})
	for v in (schema.get("views") or []):
		view_id = v.get("id", "")
		row_merge("views", ["crm", "id"], {"id": view_id, "crm": crm_id, "name": v.get("name", ""), "viewtype": v.get("viewtype", "board"), "filter": v.get("filter", ""), "columns": v.get("columns", ""), "rows": v.get("rows", ""), "sort": v.get("sort", ""), "direction": v.get("direction", "asc"), "rank": v.get("rank", 0), "border": v.get("border", "")})
		fields_csv = v.get("fields", "")
		if fields_csv:
			rank = 0
			for field_id in fields_csv.split(","):
				if field_id:
					# view_fields has an editable rank; reconcile it.
					row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field_id, "rank": rank})
					rank += 1
		classes_csv = v.get("classes", "")
		if classes_csv:
			for class_id in classes_csv.split(","):
				if class_id:
					# (crm, view, class) has no payload columns.
					row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": class_id})
	for obj in (schema.get("objects") or []):
		if not mochi.db.exists("select 1 from objects where id=?", obj.get("id", "")):
			row_merge("objects", ["id"], {"id": obj.get("id", ""), "crm": crm_id, "class": obj.get("class", ""), "parent": obj.get("parent", ""), "rank": obj.get("rank", 0), "created": obj.get("created", 0), "updated": obj.get("updated", 0)})
		obj_atts = obj.get("attachments") or []
		if obj_atts:
			mochi.attachment.store(obj_atts, crm_id, obj.get("id", ""))
		values = obj.get("values")
		if values:
			for field in values:
				row_merge("values", ["object", "field"], {"object": obj.get("id", ""), "field": field, "value": values[field]})
		for c in (obj.get("comments") or []):
			if not mochi.db.exists("select 1 from comments where id=?", c.get("id", "")):
				row_merge("comments", ["id"], {"id": c.get("id", ""), "object": obj.get("id", ""), "parent": c.get("parent", ""), "author": c.get("author", ""), "name": c.get("name", ""), "content": c.get("content", ""), "created": c.get("created", ""), "edited": c.get("edited", 0)})
			c_atts = c.get("attachments") or []
			if c_atts:
				mochi.attachment.store(c_atts, crm_id, c.get("id", ""))
		for act in (obj.get("activity") or []):
			# Activity is append-only; ignore is correct.
			mochi.db.execute(
				"insert or ignore into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
				act.get("id", ""), obj.get("id", ""), act.get("user", ""),
				act.get("action", ""), act.get("field", ""),
				act.get("oldvalue", ""), act.get("newvalue", ""),
				act.get("created", 0)
			)
	for l in (schema.get("links") or []):
		# (crm, source, target, linktype) is the full key; links are
		# created/deleted, never edited in place.
		row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": l.get("source", ""), "target": l.get("target", ""), "linktype": l.get("linktype", ""), "created": 0})

# Send all existing crm data to a new subscriber
def send_crm_data(crm_id, subscriber_id):
	h = p2p_headers(crm_id, subscriber_id, "sync/batch")

	# Collect all data into a single batch message
	batch = {"crm": crm_id, "classes": [], "views": [], "objects": [], "links": []}

	# Collect classes with their fields, options, and hierarchy
	types = mochi.db.rows("select * from classes where crm=?", crm_id)
	for t in types:
		class_data = {"id": t["id"], "name": t["name"], "rank": t["rank"], "title": t["title"]}

		# Hierarchy
		parents = mochi.db.rows("select parent from hierarchy where crm=? and class=?", crm_id, t["id"])
		if parents:
			class_data["parents"] = [p["parent"] for p in parents]

		# Fields and their options
		fields = mochi.db.rows("select * from fields where crm=? and class=? order by rank", crm_id, t["id"])
		field_list = []
		for f in fields:
			field_data = {
				"id": f["id"], "name": f["name"], "fieldtype": f["fieldtype"],
				"flags": f["flags"], "multi": f["multi"], "rank": f["rank"],
				"card": f["card"], "position": f["position"], "rows": f["rows"]
			}
			options = mochi.db.rows("select * from options where crm=? and class=? and field=? order by rank", crm_id, t["id"], f["id"])
			if options:
				field_data["options"] = [{"id": o["id"], "name": o["name"], "colour": o["colour"], "icon": o["icon"], "rank": o["rank"]} for o in options]
			field_list.append(field_data)
		class_data["fields"] = field_list
		batch["classes"].append(class_data)

	# Collect views
	views = mochi.db.rows("select * from views where crm=?", crm_id)
	all_view_classes = mochi.db.rows("select view, class from view_classes where crm=?", crm_id) or []
	vc_map = {}
	for vc in all_view_classes:
		vc_map.setdefault(vc["view"], []).append(vc["class"])
	all_view_fields = mochi.db.rows("select view, field from view_fields where crm=? order by rank", crm_id) or []
	vf_map = {}
	for vf in all_view_fields:
		vf_map.setdefault(vf["view"], []).append(vf["field"])
	for v in views:
		batch["views"].append({
			"id": v["id"], "name": v["name"], "viewtype": v["viewtype"],
			"filter": v["filter"], "columns": v["columns"], "rows": v["rows"],
			"sort": v["sort"], "direction": v["direction"], "rank": v["rank"],
			"fields": ",".join(vf_map.get(v["id"], [])),
			"classes": ",".join(vc_map.get(v["id"], [])),
			"border": v["border"]
		})

	# Collect objects with values, comments, and attachments
	objects = mochi.db.rows("select * from objects where crm=?", crm_id)
	for obj in objects:
		obj_data = {
			"id": obj["id"], "class": obj["class"],
			"parent": obj["parent"], "rank": obj["rank"],
			"created": obj["created"], "updated": obj["updated"]
		}

		# Values
		vals = mochi.db.rows("select field, value from \"values\" where object=?", obj["id"])
		if vals:
			values_map = {}
			for v in vals:
				values_map[v["field"]] = v["value"]
			obj_data["values"] = values_map

		# Comments
		comments = mochi.db.rows("select * from comments where object=? order by created", obj["id"]) or []
		if comments:
			comment_list = []
			for c in comments:
				comment_data = {
					"id": c["id"], "object": obj["id"],
					"parent": c["parent"], "author": c["author"], "name": c["name"],
					"content": c["content"], "created": c["created"]
				}
				comment_data["attachments"] = mochi.attachment.list(c["id"], crm_id) or []
				comment_list.append(comment_data)
			obj_data["comments"] = comment_list

		# Object attachments
		obj_attachments = mochi.attachment.list(obj["id"], crm_id) or []
		if obj_attachments:
			obj_data["attachments"] = obj_attachments

		# Activity history
		acts = mochi.db.rows("select id, user, action, field, oldvalue, newvalue, created from activity where object=? order by created", obj["id"]) or []
		if acts:
			obj_data["activity"] = acts

		batch["objects"].append(obj_data)

	# Collect links
	links = mochi.db.rows("select l.source, l.target, l.linktype from links l join objects o on l.source = o.id where o.crm=?", crm_id)
	for l in links:
		batch["links"].append({"source": l["source"], "target": l["target"], "linktype": l["linktype"]})

	# Send everything in one message
	mochi.message.send(h, batch)

# Handle subscribe event from a remote user
def event_subscribe(e):
	crm_id = e.header("to")

	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		return

	subscriber_id = e.header("from")
	if not mochi.text.valid(subscriber_id, "entity"):
		return

	# Check subscriber has at least view access
	if not check_crm_access(subscriber_id, crm_id, "view"):
		return

	name = e.content("name")
	if not mochi.text.valid(name, "line"):
		return

	now = mochi.time.now()
	row_merge("subscribers", ["crm", "id"], {"crm": crm_id, "id": subscriber_id, "name": name, "subscribed": now})

	# Update crm timestamp
	row_set("crms", ["id"], "id=?", [crm_id], {"updated": now})
	# Send websocket notification for real-time UI updates
	fingerprint = mochi.entity.fingerprint(crm_id)
	if fingerprint:
		mochi.websocket.write(fingerprint, {"type": "crm/update", "crm": crm_id})

	# Sync all existing crm data to the new subscriber
	send_crm_data(crm_id, subscriber_id)

# Handle unsubscribe event from a remote user
def event_unsubscribe(e):
	crm_id = e.header("to")

	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		return

	subscriber_id = e.header("from")

	# Clean up watchers created by this subscriber
	row_remove("watchers", ["object", "user"], "user=? and object in (select id from objects where crm=?)", [subscriber_id, crm_id])
	# Clean up activity records by this subscriber
	mochi.db.execute("delete from activity where user=? and object in (select id from objects where crm=?)", subscriber_id, crm_id)

	# Remove subscriber
	row_remove("subscribers", ["crm", "id"], "crm=? and id=?", [crm_id, subscriber_id])
	# Update crm timestamp
	row_set("crms", ["id"], "id=?", [crm_id], {"updated": mochi.time.now()})
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
	delete_crm_comment_attachments(crm_id)
	purge_crm(crm_id)
# ============================================================================
# Content Sync Event Handlers (received by subscribers)
# ============================================================================

# Handle batched sync data from owner (single message with all CRM data)
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
	now = mochi.time.now()

	# Process classes
	classes = e.content("classes") or []
	for t in classes:
		row_merge("classes", ["crm", "id"], {"crm": crm_id, "id": t["id"], "name": t["name"], "rank": t.get("rank", 0), "title": t.get("title", "title")})
		# Hierarchy
		parents = t.get("parents")
		if parents:
			row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and class=?", [crm_id, t["id"]])
			for p in parents:
				row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": t["id"], "parent": p})
		# Fields
		for f in (t.get("fields") or []):
			row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": t["id"], "id": f["id"], "name": f["name"], "fieldtype": f["fieldtype"], "flags": f.get("flags", ""), "multi": f.get("multi", 0), "rank": f.get("rank", 0), "card": f.get("card", ""), "position": f.get("position", ""), "rows": f.get("rows", 0)})
			# Options
			for o in (f.get("options") or []):
				row_merge("options", ["crm", "class", "field", "id"], {"crm": crm_id, "class": t["id"], "field": f["id"], "id": o["id"], "name": o["name"], "colour": o.get("colour", "#94a3b8"), "icon": o.get("icon", ""), "rank": o.get("rank", 0)})

	# Process views
	for v in (e.content("views") or []):
		row_merge("views", ["crm", "id"], {"crm": crm_id, "id": v["id"], "name": v["name"], "viewtype": v["viewtype"], "filter": v.get("filter", ""), "columns": v.get("columns", ""), "rows": v.get("rows", ""), "sort": v.get("sort", ""), "direction": v.get("direction", ""), "rank": v.get("rank", 0), "border": v.get("border", "")})
		# View fields
		row_remove("view_fields", ["crm", "view", "field"], "crm=? and view=?", [crm_id, v["id"]])
		fields_csv = v.get("fields", "")
		if fields_csv:
			for i, field_id in enumerate(fields_csv.split(",")):
				if field_id:
					row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": v["id"], "field": field_id, "rank": i})
		# View classes
		row_remove("view_classes", ["crm", "view", "class"], "crm=? and view=?", [crm_id, v["id"]])
		classes_csv = v.get("classes", "")
		if classes_csv:
			for class_id in classes_csv.split(","):
				if class_id:
					row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": v["id"], "class": class_id})
	# Process objects
	for obj in (e.content("objects") or []):
		if not mochi.db.exists("select 1 from objects where id=?", obj["id"]):
			row_merge("objects", ["id"], {"id": obj["id"], "crm": crm_id, "class": obj.get("class", ""), "parent": obj.get("parent", ""), "rank": obj.get("rank", 0), "created": obj.get("created", now), "updated": obj.get("updated", now)})
		# Values
		values = obj.get("values")
		if values:
			for field, value in values.items():
				row_merge("values", ["object", "field"], {"object": obj["id"], "field": field, "value": value})
		# Comments
		for c in (obj.get("comments") or []):
			if not mochi.db.exists("select 1 from comments where id=?", c["id"]):
				row_merge("comments", ["id"], {"id": c["id"], "object": obj["id"], "parent": c.get("parent", ""), "author": c.get("author", ""), "name": c.get("name", ""), "content": c.get("content", ""), "created": c.get("created", now), "edited": c.get("edited", 0)})
		# Activity history
		for act in (obj.get("activity") or []):
			mochi.db.execute(
				"insert or ignore into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
				act["id"], obj["id"], act.get("user", ""), act.get("action", ""),
				act.get("field", ""), act.get("oldvalue", ""), act.get("newvalue", ""),
				act.get("created", now)
			)

	# Process links
	for l in (e.content("links") or []):
		row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": l["source"], "target": l["target"], "linktype": l.get("linktype", "relates"), "created": l.get("created", 0)})

	# Mark the subscription's initial bulk content as arrived so the board stops
	# showing its loading state and renders the now-complete data.
	row_set("crms", ["id"], "id=? and owner=0", [crm_id], {"populated": 1})
	# Notify UI
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/update", "crm": crm_id})

# Helper to verify a content event is for a crm we subscribe to
# unsubscribe_stale tells a CRM owner to drop this member when a broadcast
# arrives for a CRM the member no longer holds locally. Subscribe writes the
# local crms(owner=0) row before notifying the owner, so a missing row in a
# broadcast handler always means a stale roster entry, never an in-flight
# subscribe. event_unsubscribe deletes by (crm, member), so a non-member
# unsubscribe is a harmless no-op. The broadcast headers invert: from=crm,
# to=this member.
def unsubscribe_stale(e):
	crm_id = e.header("from")
	member_id = e.header("to")
	if crm_id and member_id:
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
	return crm_id

# CRM updated
def event_crm_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	name = e.content("name")
	description = e.content("description")
	if name != None:
		row_set("crms", ["id"], "id=?", [crm_id], {"name": name})
	if description != None:
		row_set("crms", ["id"], "id=?", [crm_id], {"description": description})
	row_set("crms", ["id"], "id=?", [crm_id], {"updated": mochi.time.now()})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/update", "crm": crm_id})

# Object created
def event_object_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	object_id = e.content("id")
	class_id = e.content("class") or ""
	# Skip when the class isn't local yet — objects(crm,class) FK would
	# otherwise abort the handler. Resync pulls the canonical schema so
	# future events apply cleanly.
	if class_id and not mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id):
		request_resync(crm_id)
		return
	if not mochi.db.exists("select 1 from objects where id=?", object_id):
		row_merge("objects", ["id"], {"id": object_id, "crm": crm_id, "class": class_id, "parent": e.content("parent") or "", "rank": e.content("rank") or 0, "created": e.content("created") or mochi.time.now(), "updated": e.content("updated") or mochi.time.now()})
	# Store field values included in the broadcast
	values = e.content("values") or {}
	for field, value in values.items():
		row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": value})
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
		row_merge("watchers", ["object", "user"], {"object": object_id, "user": local_id, "created": e.content("created") or mochi.time.now()})
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

	# LWW gate: drop the event when its `updated` is no newer than the
	# locally-stored row's updated. Concurrent reparenting / reclass on
	# the same object from different subscriber hosts would otherwise
	# overwrite each other; the gate makes the lower-timestamp event
	# lose deterministically. Backwards-compatible with senders that
	# don't yet include the field — we fall back to local now.
	now = mochi.time.now()
	incoming = str(e.content("updated", "0"))
	if mochi.text.valid(incoming, "integer"):
		incoming = int(incoming)
	else:
		incoming = 0
	if incoming:
		local = mochi.db.row("select updated from objects where id=? and crm=?", object_id, crm_id)
		if local and local["updated"] and incoming <= local["updated"]:
			return

	class_id = e.content("class")
	parent = e.content("parent")
	rank = e.content("rank")
	if class_id:
		row_set("objects", ["id"], "id=? and crm=?", [object_id, crm_id], {"class": class_id})
	if parent != None:
		row_set("objects", ["id"], "id=? and crm=?", [object_id, crm_id], {"parent": parent})
	if rank != None:
		row_set("objects", ["id"], "id=? and crm=?", [object_id, crm_id], {"rank": rank})
	row_set("objects", ["id"], "id=? and crm=?", [object_id, crm_id], {"updated": incoming if incoming else now})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "object/update", "crm": crm_id, "id": object_id})
	# Notify local user if watching
	if not e.content("sync"):
		user = e.content("user") or ""
		local_id = e.header("to")
		if local_id:
			notify_watchers(object_id, crm_id, local_id, user, mochi.app.label("notifications.body.updated"))

# Batched rank update from a move. One inbound event carries the new rank
# for every object in the affected scope; we apply them all under the same
# subscription verification + websocket notification as a single
# object/update. No LWW gate because rank-only updates are derived from
# the owner's authoritative renumber — applying them out of order with
# concurrent moves still converges since the next move re-broadcasts the
# whole scope.
def event_object_ranks(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	ranks = e.content("ranks") or []
	if not ranks:
		return
	now = mochi.time.now()
	for r in ranks:
		obj_id = r.get("id")
		rank = r.get("rank")
		if obj_id and rank != None:
			row_set("objects", ["id"], "id=? and crm=?", [obj_id, crm_id], {"rank": rank, "updated": now})
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
	# Notify local user before deleting watchers
	user = e.content("user") or ""
	local_id = e.header("to")
	if local_id:
		notify_watchers(object_id, crm_id, local_id, user, mochi.app.label("notifications.body.deleted"))
	row_remove("watchers", ["object", "user"], "object=?", [object_id])
	mochi.db.execute("delete from activity where object=?", object_id)
	delete_object_comments(object_id, crm_id)
	row_remove("values", ["object", "field"], "object=?", [object_id])
	row_remove("links", ["source", "target", "linktype"], "source=? or target=?", [object_id, object_id])
	row_remove("objects", ["id"], "id=? and crm=?", [object_id, crm_id])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "object/delete", "crm": crm_id, "id": object_id})

# Values updated
def event_values_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	object_id = e.content("id")
	if not object_id:
		return
	values = e.content("values")
	if not values:
		return
	# Skip when the referenced object isn't local yet. The values.object FK
	# would otherwise abort the handler and the update would be lost
	# forever (the owner has no idea we couldn't apply it). request_resync
	# pulls the canonical schema so we converge on the next event.
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		request_resync(crm_id)
		return
	for field in values:
		row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": values[field]})
	row_set("objects", ["id"], "id=? and crm=?", [object_id, crm_id], {"updated": mochi.time.now()})
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
	if not activity_id or not object_id:
		return
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		request_resync(crm_id)
		return
	created = e.content("created")
	if not mochi.text.valid(str(created), "integer"):
		created = mochi.time.now()
	else:
		created = int(created)
	mochi.db.execute(
		"insert or ignore into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
		activity_id, object_id, e.content("user") or "",
		e.content("action") or "", e.content("field") or "",
		e.content("oldvalue") or "", e.content("newvalue") or "",
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
	if not comment_id or not object_id:
		return
	if not mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id):
		return
	parent = e.content("parent") or ""
	content = e.content("content") or ""
	name = e.content("name") or ""
	if not content.strip():
		return
	now = mochi.time.now()
	if not mochi.db.exists("select 1 from comments where id=?", comment_id):
		row_merge("comments", ["id"], {"id": comment_id, "object": object_id, "parent": parent, "author": sender, "name": name, "content": content.strip(), "created": now, "edited": 0})
	# Store attachment metadata from the subscriber's event
	attachments = e.content("attachments") or []
	if attachments:
		mochi.attachment.store(attachments, sender, comment_id)
	row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
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
	row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
	names = e.content("names") or []
	for name in names:
		log_activity(object_id, sender, "attached", "", "", name)
	# Store attachment metadata from the subscriber's event
	attachments = e.content("attachments") or []
	if attachments:
		mochi.attachment.store(attachments, sender, object_id)
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
	if attachments and object_id:
		mochi.attachment.store(attachments, e.header("from"), object_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "attachment/create", "crm": crm_id, "object": object_id})

# Attachment removed by owner
def event_attachment_remove(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	attachment_id = e.content("attachment")
	if attachment_id:
		mochi.attachment.delete(attachment_id)
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
	# Skip when the comment's object isn't local yet — comments.object FK
	# would otherwise abort the handler and the comment would be lost.
	if not object_id or not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
		request_resync(crm_id)
		return
	if not mochi.db.exists("select 1 from comments where id=?", comment_id):
		row_merge("comments", ["id"], {"id": comment_id, "object": object_id, "parent": e.content("parent") or "", "author": e.content("author") or "", "name": e.content("name") or "", "content": e.content("content") or "", "created": e.content("created") or mochi.time.now(), "edited": 0})
	# Store attachment metadata from the event
	attachments = e.content("attachments") or []
	if attachments:
		mochi.attachment.store(attachments, e.header("from"), comment_id)
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
				row_merge("watchers", ["object", "user"], {"object": object_id, "user": local_id, "created": e.content("created") or mochi.time.now()})
			name = e.content("name") or "Someone"
			excerpt = (e.content("content") or "")[:80]
			notify_watchers(object_id, crm_id, local_id, user, mochi.app.label("notifications.body.commented", name=name, excerpt=excerpt))

# Comment updated
def event_comment_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	comment_id = e.content("id")
	if not comment_id:
		return
	# Skip when the comment isn't local yet — the UPDATE would silently
	# no-op, leaving us with an out-of-date row until something else
	# triggers a sync.
	if not mochi.db.exists("select 1 from comments where id=?", comment_id):
		request_resync(crm_id)
		return
	content = e.content("content")
	if content:
		row_set("comments", ["id"], "id=?", [comment_id], {"content": content, "edited": mochi.time.now()})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "comment/update", "crm": crm_id, "id": comment_id})

# Comment deleted
def event_comment_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	comment_id = e.content("id")
	if not comment_id:
		return
	delete_comment_tree(comment_id, crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "comment/delete", "crm": crm_id, "id": comment_id})

# Link created
def event_link_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	source = e.content("source") or ""
	target = e.content("target") or ""
	# Skip when either endpoint isn't local yet — links FKs would abort.
	if not source or not target:
		return
	if not mochi.db.exists("select 1 from objects where id=? and crm=?", source, crm_id) or \
		not mochi.db.exists("select 1 from objects where id=? and crm=?", target, crm_id):
		request_resync(crm_id)
		return
	row_merge("links", ["source", "target", "linktype"], {"crm": crm_id, "source": source, "target": target, "linktype": e.content("linktype") or "related", "created": e.content("created") or mochi.time.now()})
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
	row_remove("links", ["source", "target", "linktype"], "source=? and target=? and linktype=?", [e.content("source") or "", e.content("target") or "", e.content("linktype") or "related"])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "link/delete", "crm": crm_id})

# View created
def event_view_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	view_id = e.content("id")
	if not view_id:
		return
	row_merge("views", ["crm", "id"], {"id": view_id, "crm": crm_id, "name": e.content("name") or "", "viewtype": e.content("viewtype") or "board", "filter": e.content("filter") or "", "columns": e.content("columns") or "", "rows": e.content("rows") or "", "sort": e.content("sort") or "", "direction": e.content("direction") or "asc", "rank": e.content("rank") or 0, "border": e.content("border") or ""})
	# Sync view fields
	fields_csv = e.content("fields") or ""
	if fields_csv:
		rank = 0
		for field_id in fields_csv.split(","):
			if field_id:
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field_id, "rank": rank})
				rank += 1
	# Sync view classes
	classes_csv = e.content("classes") or ""
	if classes_csv:
		for class_id in classes_csv.split(","):
			if class_id:
				row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": class_id})
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
		row_set("views", ["crm", "id"], "id=? and crm=?", [view_id, crm_id], {"name": name})
	if viewtype:
		row_set("views", ["crm", "id"], "id=? and crm=?", [view_id, crm_id], {"viewtype": viewtype})
	if filter_val != None:
		row_set("views", ["crm", "id"], "id=? and crm=?", [view_id, crm_id], {"filter": filter_val})
	if columns != None:
		row_set("views", ["crm", "id"], "id=? and crm=?", [view_id, crm_id], {"columns": columns})
	if rows != None:
		row_set("views", ["crm", "id"], "id=? and crm=?", [view_id, crm_id], {"rows": rows})
	if sort != None:
		row_set("views", ["crm", "id"], "id=? and crm=?", [view_id, crm_id], {"sort": sort})
	if direction != None:
		row_set("views", ["crm", "id"], "id=? and crm=?", [view_id, crm_id], {"direction": direction})
	border = e.content("border")
	if border != None:
		row_set("views", ["crm", "id"], "id=? and crm=?", [view_id, crm_id], {"border": border})
	# Sync view fields if provided
	fields_csv = e.content("fields")
	if fields_csv != None:
		row_remove("view_fields", ["crm", "view", "field"], "crm=? and view=?", [crm_id, view_id])
		rank = 0
		for field_id in fields_csv.split(","):
			if field_id:
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field_id, "rank": rank})
				rank += 1
	# Sync view classes if provided
	classes_csv = e.content("classes")
	if classes_csv != None:
		row_remove("view_classes", ["crm", "view", "class"], "crm=? and view=?", [crm_id, view_id])
		for class_id in classes_csv.split(","):
			if class_id:
				row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": class_id})
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
	row_remove("views", ["crm", "id"], "id=? and crm=?", [view_id, crm_id])
	row_remove("view_fields", ["crm", "view", "field"], "view=? and crm=?", [view_id, crm_id])
	row_remove("view_classes", ["crm", "view", "class"], "view=? and crm=?", [view_id, crm_id])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "view/delete", "crm": crm_id, "id": view_id})

# Type created
def event_class_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	row_merge("classes", ["crm", "id"], {"id": e.content("id"), "crm": crm_id, "name": e.content("name") or "", "rank": e.content("rank") or 0, "title": e.content("title") or ""})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "class/create", "crm": crm_id, "id": e.content("id")})

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
		row_set("classes", ["crm", "id"], "id=? and crm=?", [class_id, crm_id], {"name": name})
	title = e.content("title")
	if title != None:
		row_set("classes", ["crm", "id"], "id=? and crm=?", [class_id, crm_id], {"title": title})
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
	row_remove("options", ["crm", "class", "field", "id"], "crm=? and class=?", [crm_id, class_id])
	row_remove("fields", ["crm", "class", "id"], "crm=? and class=?", [crm_id, class_id])
	row_remove("view_classes", ["crm", "view", "class"], "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and parent=?", [crm_id, class_id])
	row_remove("classes", ["crm", "id"], "id=? and crm=?", [class_id, crm_id])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "class/delete", "crm": crm_id, "id": class_id})

# Hierarchy set
def event_hierarchy_set(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	parents = e.content("parents")
	if not class_id:
		return
	# Clear existing hierarchy for this class
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and class=?", [crm_id, class_id])
	# Insert new parents
	if parents:
		for parent in parents:
			row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": class_id, "parent": parent})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "hierarchy/set", "crm": crm_id, "class": class_id})

# Field created
def event_field_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": e.content("class") or "", "id": e.content("id") or "", "name": e.content("name") or "", "fieldtype": e.content("fieldtype") or "text", "flags": e.content("flags") or "", "multi": e.content("multi") or 0, "rank": e.content("rank") or 0, "card": e.content("card") or 1, "position": e.content("position") or "", "rows": e.content("rows") or 1})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "field/create", "crm": crm_id, "class_id": e.content("class"), "id": e.content("id")})

# Field updated
def event_field_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	field_id = e.content("id")
	if not class_id or not field_id:
		return
	# Handle field ID rename
	old_id = e.content("old_id")
	if old_id != None:
		rename_field_id(crm_id, class_id, old_id, field_id)
	# Use old_id to update the correct row for attribute changes, since rename already happened
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
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"name": name})
	if flags != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"flags": flags})
	if multi != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"multi": multi})
	if card != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"card": card})
	if min_val != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"min": min_val})
	if max_val != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"max": max_val})
	if pattern != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"pattern": pattern})
	if minlength != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"minlength": minlength})
	if maxlength != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"maxlength": maxlength})
	if prefix != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"prefix": prefix})
	if suffix != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"suffix": suffix})
	if format_str != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"format": format_str})
	if position != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"position": position})
	if rows_val != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, current_id], {"rows": rows_val})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "field/update", "crm": crm_id, "class_id": class_id, "id": field_id})

# Field deleted
def event_field_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	field_id = e.content("id")
	if not class_id or not field_id:
		return
	row_remove("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=?", [crm_id, class_id, field_id])
	row_remove("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id])
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "field/delete", "crm": crm_id, "class_id": class_id, "id": field_id})

# Field reorder
def event_field_reorder(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	class_id = e.content("class")
	order = e.content("order")
	if not class_id or not order:
		return
	for i, field_id in enumerate(order):
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rank": i})
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "field/reorder", "crm": crm_id, "class_id": class_id})

# Option created
def event_option_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	row_merge("options", ["crm", "class", "field", "id"], {"crm": crm_id, "class": e.content("class") or "", "field": e.content("field") or "", "id": e.content("id") or "", "name": e.content("name") or "", "colour": e.content("colour") or "#94a3b8", "icon": e.content("icon") or "", "rank": e.content("rank") or 0})
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
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"name": name})
	if colour != None:
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"colour": colour})
	if icon != None:
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"icon": icon})
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
	row_remove("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id])
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
	order = e.content("order")
	if not class_id or not field_id or not order:
		return
	for i, option_id in enumerate(order):
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"rank": i})
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
	"watcher/add": "view", "watcher/remove": "view",
	"object/create": "write", "object/update": "write", "object/delete": "write",
	"object/move": "write", "values/set": "write", "value/set": "write",
	"link/create": "write", "link/delete": "write",
	"attachment/delete": "write",
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
	action = e.content("action")
	params = e.content("params") or {}
	# Authorship and ownership are governed by the authenticated P2P sender, not
	# a content-supplied id: a content "_user" is spoofable and would let a peer
	# post as, or edit/delete the comments of, another user.
	user_id = requester
	user_name = params.get("_name", "")

	crm_id = params.get("crm")
	if not crm_id:
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
	elif action == "watcher/add":
		result = do_watcher_add(crm_id, params, user_id)
	elif action == "watcher/remove":
		result = do_watcher_remove(crm_id, params, user_id)
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
def event_access_check(e):
	crm_id = e.header("to")
	user_id = e.content("user") or e.header("from")
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
	comment_id = params.get("id") or mochi.uid()
	now = mochi.time.now()
	if not mochi.db.exists("select 1 from comments where id=?", comment_id):
		row_merge("comments", ["id"], {"id": comment_id, "object": object_id, "parent": parent, "author": user_id, "name": user_name, "content": content.strip(), "created": now, "edited": 0})
	row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
	log_activity(object_id, user_id, "commented")
	# Auto-watch commenter on owner's server
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": user_id, "created": now})
	# Include attachments in broadcast
	comment_attachments = mochi.attachment.list(comment_id, crm_id) or []
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
	return {"id": comment_id, "author": user_id, "name": user_name,
			"content": content.strip(), "created": now}

def do_comment_update(crm_id, crm, params, user_id):
	object_id = params.get("object")
	comment_id = params.get("comment")
	content = params.get("content")
	if not object_id or not comment_id:
		return {"error": "errors.object_and_comment_id_required", "code": 400}
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
	row_set("comments", ["id"], "id=?", [comment_id], {"content": content.strip(), "edited": now})
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

# Watcher helpers
def do_watcher_add(crm_id, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "errors.object_id_required", "code": 400}
	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	now = mochi.time.now()
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": user_id, "created": now})
	return {"success": True, "watching": True}

def do_watcher_remove(crm_id, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "errors.object_id_required", "code": 400}
	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	row_remove("watchers", ["object", "user"], "object=? and user=?", [object_id, user_id])
	return {"success": True, "watching": False}

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

	# Check hierarchy rules
	parent_class = ""
	if parent:
		parent_row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
		if not parent_row:
			return {"error": "errors.parent_object_not_found", "code": 404}
		parent_class = parent_row["class"]
	allowed = mochi.db.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, obj_class, parent_class)
	if not allowed:
		return {"error": "errors.hierarchy_disallowed", "code": 400}

	title_field_row = mochi.db.row("select title from classes where crm=? and id=?", crm_id, obj_class)
	title_field = title_field_row["title"] if title_field_row else ""
	initial_rank = rank_after_all(crm_id, None)
	object_id = mochi.uid()
	now = mochi.time.now()
	row_merge("objects", ["id"], {"id": object_id, "crm": crm_id, "class": obj_class, "parent": parent, "rank": initial_rank, "created": now, "updated": now})
	values = {}
	if title and title_field:
		row_merge("values", ["object", "field"], {"object": object_id, "field": title_field, "value": title})
		values[title_field] = title
	log_activity(object_id, user_id, "created")
	row_merge("watchers", ["object", "user"], {"object": object_id, "user": user_id, "created": now})
	broadcast_event(crm_id, "object/create", {
		"crm": crm_id, "id": object_id, "class": obj_class,
		"parent": parent, "rank": initial_rank, "values": values,
		"created": now, "updated": now, "user": user_id
	})
	# Notify owner when subscriber creates an object
	owner_id = get_owner_identity(crm_id)
	if owner_id and owner_id != user_id:
		obj = mochi.db.row("select class from objects where id=?", object_id)
		display = get_object_display(crm, obj, object_id)
		fp = mochi.entity.fingerprint(crm_id)
		url = "/crm/" + fp + "/" + object_id if fp else "/crm"
		notify("update/created", crm_id, display, mochi.app.label("notifications.body.created"), url, event_id="update/created:" + object_id)
	return {"id": object_id, "rank": initial_rank, "created": now, "updated": now}

def do_object_update(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "errors.object_id_required", "code": 400}
	row = mochi.db.row("select * from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	now = mochi.time.now()
	parent = params.get("parent")
	if parent != None:
		old_parent = row["parent"]
		if parent != old_parent:
			if parent and would_create_cycle(object_id, parent):
				return {"error": "errors.cannot_set_parent_would_create_a_cycle", "code": 400}
			if parent:
				parent_row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
				if not parent_row:
					return {"error": "errors.parent_object_not_found", "code": 404}
				parent_class = parent_row["class"]
			else:
				parent_class = ""
			allowed = mochi.db.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, row["class"], parent_class)
			if not allowed:
				return {"error": "errors.parent_hierarchy_disallowed", "code": 400}
			row_set("objects", ["id"], "id=?", [object_id], {"parent": parent, "updated": now})
			log_activity(object_id, user_id, "moved", "parent", old_parent, parent)

			# Sync child's column/row values to match new parent
			if parent:
				parent_values = mochi.db.rows('select field, value from "values" where object=?', parent) or []
				parent_val_map = {v["field"]: v["value"] for v in parent_values}
				views = mochi.db.rows("select columns, rows from views where crm=?", crm_id) or []
				sync_fields = {}
				for view in views:
					if view["columns"]:
						sync_fields[view["columns"]] = True
					if view["rows"]:
						sync_fields[view["rows"]] = True
				all_ids = [object_id] + get_all_descendants(object_id)
				for sync_id in all_ids:
					for field_id in sync_fields:
						parent_val = parent_val_map.get(field_id, "")
						row_merge("values", ["object", "field"], {"object": sync_id, "field": field_id, "value": parent_val})
	new_class = params.get("class")
	if new_class and new_class != row["class"]:
		class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, new_class)
		if class_row:
			row_set("objects", ["id"], "id=?", [object_id], {"class": new_class, "updated": now})
			log_activity(object_id, user_id, "updated", "class", row["class"], new_class)
	row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
	broadcast_event(crm_id, "object/update", {
		"crm": crm_id, "id": object_id,
		"parent": parent if parent != None else row["parent"],
		"class": new_class if new_class and new_class != row["class"] else row["class"],
		"user": user_id
	})
	# Notify owner if watching
	owner_id = get_owner_identity(crm_id)
	notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.updated"))
	return {"success": True}

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
	row = mochi.db.row("select id, class, rank from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "errors.object_not_found", "code": 404}
	if check_length(params.get("value"), 50000):
		return {"error": "errors.value_too_long", "code": 400}
	if check_length(params.get("row_value"), 50000):
		return {"error": "errors.value_too_long", "code": 400}
	old_rank = row["rank"]
	obj_class = row["class"]
	field = params.get("field", "")
	if check_length(field, 100):
		return {"error": "errors.field_name_too_long", "code": 400}
	if field and not mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, obj_class, field):
		return {"error": "errors.field_not_found", "code": 400}
	value = params.get("value")
	new_rank = params.get("rank")
	old_value_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field)
	old_value = old_value_row["value"] if old_value_row else ""
	target_value = value if value else old_value
	value_changed = old_value != target_value
	if value_changed:
		row_merge("values", ["object", "field"], {"object": object_id, "field": field, "value": target_value})
		log_activity(object_id, user_id, "updated", field, old_value, target_value)
	scope_parent = params.get("scope_parent", None)
	if new_rank != None:
		# Fractional key between the neighbours at the drop slot (#53): one write,
		# converges under multi-master — no whole-scope renumber.
		new_key = rank_move_key(crm_id, object_id, field, target_value, scope_parent, int(new_rank))
		row_set("objects", ["id"], "id=?", [object_id], {"rank": new_key})
	elif value_changed:
		# Moving to a new column without a specific rank — append to its end.
		# Anchor on the crm-wide max for a globally-unique key (see rank_after_all);
		# crm-max >= the column's last, so it still lands last.
		new_key = rank_after_all(crm_id, object_id)
		row_set("objects", ["id"], "id=?", [object_id], {"rank": new_key})
	row_field = params.get("row_field")
	row_value = params.get("row_value")
	if check_length(row_field, 100):
		return {"error": "errors.field_name_too_long", "code": 400}
	if row_field and not mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, obj_class, row_field):
		return {"error": "errors.field_not_found", "code": 400}
	row_changed = False
	if row_field:
		old_row_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, row_field)
		old_row_value = old_row_row["value"] if old_row_row else ""
		if old_row_value != row_value:
			row_merge("values", ["object", "field"], {"object": object_id, "field": row_field, "value": row_value})
			log_activity(object_id, user_id, "updated", row_field, old_row_value, row_value)
			row_changed = True

	# Handle promote (clear parent)
	promote = params.get("promote", "") == "true"
	if promote:
		old_parent_row = mochi.db.row("select parent from objects where id=?", object_id)
		old_parent = old_parent_row["parent"] if old_parent_row else ""
		if old_parent:
			row_set("objects", ["id"], "id=?", [object_id], {"parent": '', "updated": mochi.time.now()})
			log_activity(object_id, user_id, "moved", "parent", old_parent, "")

	row_set("objects", ["id"], "id=?", [object_id], {"updated": mochi.time.now()})
	# Cascade status/row changes to all descendants
	if value_changed or row_changed:
		descendants = get_all_descendants(object_id)
		now = mochi.time.now()
		for desc_id in descendants:
			if value_changed:
				row_merge("values", ["object", "field"], {"object": desc_id, "field": field, "value": target_value})
			if row_changed:
				row_merge("values", ["object", "field"], {"object": desc_id, "field": row_field, "value": row_value})
			row_set("objects", ["id"], "id=?", [desc_id], {"updated": now})
	updated_values = {}
	if value_changed:
		updated_values[field] = target_value
	if row_changed:
		updated_values[row_field] = row_value
	if updated_values:
		broadcast_event(crm_id, "values/update", {
			"crm": crm_id, "id": object_id,
			"values": updated_values, "user": user_id
		})
		# Notify owner if watching
		owner_id = get_owner_identity(crm_id)
		notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.updated"))

	# Only the moved object's fractional key changed (#53) — broadcast just that
	# one row; event_object_ranks applies each entry by id.
	if new_rank != None:
		moved = mochi.db.row("select rank from objects where id=? and crm=?", object_id, crm_id)
		if moved:
			broadcast_event(crm_id, "object/ranks", {
				"crm": crm_id,
				"ranks": [{"id": object_id, "rank": moved["rank"]}],
				"user": user_id,
			})

	return {"success": True}

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

# Validate a value against a field's type and declared constraints. Returns
# {"key", "args"} describing the first violation, or None if acceptable. Empty
# values are always allowed (clearing the field); "required" is a separate
# concern. The custom-regex `pattern` constraint is not enforced here - Starlark
# has no general regex API.
def validate_field_value(crm_id, class_id, field_id, value):
	value = "" if value == None else str(value)
	if value == "":
		return None
	field = mochi.db.row("select fieldtype, min, max, minlength, maxlength from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field:
		return None
	ftype = field["fieldtype"]

	if ftype == "enumerated":
		if not mochi.db.exists("select 1 from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, value):
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
	now = mochi.time.now()
	changes = []
	values = params.get("values", {})
	for v in values.values():
		if check_length(v, 50000):
			return {"error": "errors.value_too_long", "code": 400}
	for field_id in values:
		if field_id not in valid_fields:
			continue
		new_value = values[field_id]
		invalid = validate_field_value(crm_id, row["class"], field_id, new_value)
		if invalid:
			return {"error": invalid["key"], "args": invalid.get("args"), "code": 400}
		old_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field_id)
		old_value = old_row["value"] if old_row else ""
		if str(new_value) != old_value:
			row_merge("values", ["object", "field"], {"object": object_id, "field": field_id, "value": str(new_value)})
			log_activity(object_id, user_id, "updated", field_id, old_value, str(new_value))
			changes.append(field_id)
	if changes:
		row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
		changed_values = {}
		for fid in changes:
			val = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, fid)
			if val:
				changed_values[fid] = val["value"]
		broadcast_event(crm_id, "values/update", {
			"crm": crm_id, "id": object_id, "values": changed_values, "user": user_id
		})
		# Notify owner if watching
		owner_id = get_owner_identity(crm_id)
		notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.updated"))
		# Auto-watch assigned users
		for fid in changes:
			if field_types.get(fid) == "user":
				assigned = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, fid)
				if assigned and assigned["value"]:
					row_merge("watchers", ["object", "user"], {"object": object_id, "user": assigned["value"], "created": now})
	return {"success": True, "changed": changes}

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
	old_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field_id)
	old_value = old_row["value"] if old_row else ""
	if str(new_value) != old_value:
		row_merge("values", ["object", "field"], {"object": object_id, "field": field_id, "value": str(new_value)})
		now = mochi.time.now()
		row_set("objects", ["id"], "id=?", [object_id], {"updated": now})
		log_activity(object_id, user_id, "updated", field_id, old_value, str(new_value))
		broadcast_event(crm_id, "values/update", {
			"crm": crm_id, "id": object_id,
			"values": {field_id: str(new_value)}, "user": user_id
		})
		# Notify owner if watching
		owner_id = get_owner_identity(crm_id)
		notify_watchers(object_id, crm_id, owner_id, user_id, mochi.app.label("notifications.body.updated"))
		# Auto-watch assigned user
		if field_row["fieldtype"] == "user" and str(new_value):
			row_merge("watchers", ["object", "user"], {"object": object_id, "user": str(new_value), "created": now})
	return {"success": True}

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
	row_remove("links", ["source", "target", "linktype"], "crm=? and source=? and target=? and linktype=?", [crm_id, object_id, target_id, linktype])
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
	if not mochi.attachment.exists(attachment_id):
		return {"error": "errors.attachment_not_found", "code": 404}
	mochi.attachment.delete(attachment_id, [])
	broadcast_event(crm_id, "attachment/remove", {
		"crm": crm_id, "attachment": attachment_id
	})
	return {"success": True}

# Class helpers
def do_class_create(crm_id, crm, params):
	name = params.get("name")
	if not name or not name.strip():
		return {"error": "errors.name_is_required", "code": 400}
	if check_length(name, 100):
		return {"error": "errors.name_too_long", "code": 400}
	class_id = name.strip().lower().replace(" ", "_")
	existing = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id)
	if existing:
		return {"error": "errors.class_name_taken", "code": 400}
	max_rank = mochi.db.row("select max(rank) as m from classes where crm=?", crm_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0
	row_merge("classes", ["crm", "id"], {"crm": crm_id, "id": class_id, "name": name.strip(), "rank": rank, "title": "title"})
	row_merge("fields", ["crm", "class", "id"], {"crm": crm_id, "class": class_id, "id": "title", "name": "Title", "fieldtype": "text", "flags": "required,sort", "rank": 0})
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
	title_input = params.get("title")
	if check_length(title_input, 100):
		return {"error": "errors.title_too_long", "code": 400}
	if name:
		row_set("classes", ["crm", "id"], "crm=? and id=?", [crm_id, class_id], {"name": name.strip()})
	if title_input:
		row_set("classes", ["crm", "id"], "crm=? and id=?", [crm_id, class_id], {"title": title_input})
	broadcast_event(crm_id, "class/update", {
		"crm": crm_id, "id": class_id, "name": name or class_row["name"],
		"title": title_input or class_row["title"]
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
	row_remove("options", ["crm", "class", "field", "id"], "crm=? and class=?", [crm_id, class_id])
	row_remove("fields", ["crm", "class", "id"], "crm=? and class=?", [crm_id, class_id])
	row_remove("view_classes", ["crm", "view", "class"], "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and class=?", [crm_id, class_id])
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and parent=?", [crm_id, class_id])
	row_remove("classes", ["crm", "id"], "crm=? and id=?", [crm_id, class_id])
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
	if fieldtype not in ["text", "number", "date", "enumerated", "user", "object", "checkbox", "checklist"]:
		return {"error": "errors.invalid_field_type", "code": 400}
	field_id = name.strip().lower().replace(" ", "_")
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

# Rename a field ID across all tables that reference it
def rename_field_id(crm_id, class_id, old_id, new_id):
	row_rekey("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, old_id], {"id": new_id})
	row_rekey("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=?", [crm_id, class_id, old_id], {"field": new_id})
	# Re-key field old_id -> new_id across this class's objects: re-merge each value under
	# the new field id and tombstone the old (the merge upsert handles any new_id conflict).
	for _v in mochi.db.rows("select object, value from \"values\" where field=? and object in (select id from objects where crm=? and class=?)", old_id, crm_id, class_id):
		row_merge("values", ["object", "field"], {"object": _v["object"], "field": new_id, "value": _v["value"]})
		row_remove("values", ["object", "field"], "object=? and field=?", [_v["object"], old_id])
	row_rekey("view_fields", ["crm", "view", "field"], "crm=? and field=?", [crm_id, old_id], {"field": new_id})
	mochi.db.execute("update activity set field=? where field=? and object in (select id from objects where crm=? and class=?)", new_id, old_id, crm_id, class_id)
	row_set("views", ["crm", "id"], "crm=? and columns=?", [crm_id, old_id], {"columns": new_id})
	row_set("views", ["crm", "id"], "crm=? and rows=?", [crm_id, old_id], {"rows": new_id})
	row_set("views", ["crm", "id"], "crm=? and sort=?", [crm_id, old_id], {"sort": new_id})
	row_set("views", ["crm", "id"], "crm=? and border=?", [crm_id, old_id], {"border": new_id})
	row_set("classes", ["crm", "id"], "crm=? and id=? and title=?", [crm_id, class_id, old_id], {"title": new_id})
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
	if name != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"name": name.strip()})
	if flags != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"flags": flags})
	if multi != None:
		multi_val = 1 if multi == "1" or multi == "true" else 0
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"multi": multi_val})
	if card != None:
		card_val = 1 if card == "1" or card == "true" else 0
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"card": card_val})
	if position != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"position": position})
	if rows_val != None:
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rows": int(rows_val)})
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
		update_data["old_id"] = field_id
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
	if rows_val != None:
		update_data["rows"] = int(rows_val)
	broadcast_event(crm_id, "field/update", update_data)
	return {"success": True}

def do_field_delete(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	if not class_id or not field_id:
		return {"error": "errors.type_and_field_id_required", "code": 400}
	row_remove("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=?", [crm_id, class_id, field_id])
	row_remove("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id])
	broadcast_event(crm_id, "field/delete", {"crm": crm_id, "class": class_id, "id": field_id})
	return {"success": True}

def do_field_reorder(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "errors.type_id_required", "code": 400}
	order_str = params.get("order", "")
	order = [f.strip() for f in order_str.split(",") if f.strip()]
	for i, field_id in enumerate(order):
		row_set("fields", ["crm", "class", "id"], "crm=? and class=? and id=?", [crm_id, class_id, field_id], {"rank": i})
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
	option_id = name.strip().lower().replace(" ", "_")
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
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"name": name.strip()})
	if colour != None:
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"colour": colour})
	if icon != None:
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"icon": icon})
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
	row_remove("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id])
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
		row_set("options", ["crm", "class", "field", "id"], "crm=? and class=? and field=? and id=?", [crm_id, class_id, field_id, option_id], {"rank": i})
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
	row_remove("hierarchy", ["crm", "class", "parent"], "crm=? and class=?", [crm_id, class_id])
	for parent in parents:
		if parent and parent != "":
			parent_exists = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, parent)
			if not parent_exists:
				continue
		row_merge("hierarchy", ["crm", "class", "parent"], {"crm": crm_id, "class": class_id, "parent": parent})
	broadcast_event(crm_id, "hierarchy/set", {
		"crm": crm_id, "class": class_id, "parents": parents
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
	if viewtype not in ["board", "list"]:
		return {"error": "errors.invalid_view_type", "code": 400}
	view_id = name.strip().lower().replace(" ", "_")
	existing = mochi.db.exists("select 1 from views where crm=? and id=?", crm_id, view_id)
	if existing:
		return {"error": "errors.view_name_taken", "code": 400}
	filter_str = params.get("filter", "")
	columns = params.get("columns", "")
	if viewtype == "board" and not columns:
		return {"error": "errors.columns_field_is_required_for_board_views", "code": 400}
	rows = params.get("rows", "")
	fields = params.get("fields", "title,priority,owner,due")
	sort = params.get("sort", "")
	direction = params.get("direction", "asc")
	border = params.get("border", "")
	next_rank = mochi.db.row("select coalesce(max(rank), -1) + 1 as r from views where crm=?", crm_id)
	rank = next_rank["r"] if next_rank else 0
	row_merge("views", ["crm", "id"], {"crm": crm_id, "id": view_id, "name": name.strip(), "viewtype": viewtype, "filter": filter_str, "columns": columns, "rows": rows, "sort": sort, "direction": direction, "rank": rank, "border": border})
	for i, field in enumerate(fields.split(",")):
		if field.strip():
			row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field.strip(), "rank": i})
	view_classes = params.get("classes", "")
	if view_classes:
		for cls_id in [c.strip() for c in view_classes.split(",") if c.strip()]:
			row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": cls_id})
	broadcast_event(crm_id, "view/create", {
		"crm": crm_id, "id": view_id, "name": name.strip(),
		"viewtype": viewtype, "filter": filter_str, "columns": columns,
		"rows": rows, "fields": fields, "sort": sort, "direction": direction,
		"border": border
	})
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
	name = params.get("name")
	viewtype = params.get("viewtype")
	filter_str = params.get("filter")
	columns = params.get("columns")
	rows = params.get("rows")
	fields = params.get("fields")
	sort = params.get("sort")
	direction = params.get("direction")
	if name != None and name.strip() != "":
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"name": name.strip()})
	if viewtype != None and viewtype != "":
		if viewtype not in ["board", "list"]:
			return {"error": "errors.invalid_view_type", "code": 400}
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"viewtype": viewtype})
	if filter_str != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"filter": filter_str})
	if columns != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"columns": columns})
	if rows != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"rows": rows})
	if fields != None:
		row_remove("view_fields", ["crm", "view", "field"], "crm=? and view=?", [crm_id, view_id])
		for i, field in enumerate(fields.split(",")):
			if field.strip():
				row_merge("view_fields", ["crm", "view", "field"], {"crm": crm_id, "view": view_id, "field": field.strip(), "rank": i})
	if sort != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"sort": sort})
	if direction != None and direction != "":
		if direction not in ["asc", "desc"]:
			return {"error": "errors.invalid_direction", "code": 400}
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"direction": direction})
	border = params.get("border")
	if border != None:
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"border": border})
	view_classes_input = params.get("classes")
	if view_classes_input != None:
		row_remove("view_classes", ["crm", "view", "class"], "crm=? and view=?", [crm_id, view_id])
		if view_classes_input:
			cls_ids = [c.strip() for c in view_classes_input.split(",") if c.strip()]
			for cls_id in cls_ids:
				row_merge("view_classes", ["crm", "view", "class"], {"crm": crm_id, "view": view_id, "class": cls_id})
	updated = mochi.db.row("select * from views where crm=? and id=?", crm_id, view_id)
	if updated:
		view_fields = mochi.db.rows("select field from view_fields where crm=? and view=? order by rank", crm_id, view_id) or []
		updated_fields = ",".join([vf["field"] for vf in view_fields])
		broadcast_event(crm_id, "view/update", {
			"crm": crm_id, "id": view_id,
			"name": updated["name"], "viewtype": updated["viewtype"],
			"filter": updated["filter"], "columns": updated["columns"],
			"rows": updated["rows"], "fields": updated_fields,
			"sort": updated["sort"], "direction": updated["direction"],
			"rank": updated["rank"], "border": updated["border"]
		})
	return {"success": True}

def do_view_delete(crm_id, crm, params):
	view_id = params.get("view")
	if not view_id:
		return {"error": "errors.view_id_required", "code": 400}
	count = mochi.db.row("select count(*) as cnt from views where crm=?", crm_id)
	if count and count["cnt"] <= 1:
		return {"error": "errors.cannot_delete_the_last_view", "code": 400}
	row_remove("view_fields", ["crm", "view", "field"], "crm=? and view=?", [crm_id, view_id])
	row_remove("view_classes", ["crm", "view", "class"], "crm=? and view=?", [crm_id, view_id])
	row_remove("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id])
	broadcast_event(crm_id, "view/delete", {"crm": crm_id, "id": view_id})
	return {"success": True}

def do_view_reorder(crm_id, crm, params):
	order_str = params.get("order", "")
	order = [v.strip() for v in order_str.split(",") if v.strip()]
	for i, view_id in enumerate(order):
		row_set("views", ["crm", "id"], "crm=? and id=?", [crm_id, view_id], {"rank": i})
	broadcast_event(crm_id, "view/reorder", {"crm": crm_id, "order": order})
	return {"success": True}

