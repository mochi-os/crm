# Mochi CRM app
# Copyright Alistair Cunningham 2026

# Helper to create P2P message headers
def p2p_headers(from_id, to_id, event):
	return {
		"from": from_id,
		"to": to_id,
		"service": "crm",
		"event": event
	}

# Broadcast an event to all subscribers of a crm
def broadcast_event(crm_id, event, data, exclude=None):
	subscribers = mochi.db.rows("select id from subscribers where crm=?", crm_id)
	for sub in subscribers:
		if exclude and sub["id"] == exclude:
			continue
		mochi.message.send(p2p_headers(crm_id, sub["id"], event), data)

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
		updated integer not null
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
		requests text not null default '',
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

	# 16. requests - merge requests (and future request types) attached to objects
	mochi.db.execute("""create table if not exists requests (
		id text primary key,
		object text not null references objects(id),
		type text not null default '',
		repository text not null default '',
		source text not null default '',
		target text not null default '',
		status text not null default 'open',
		title text not null default '',
		description text not null default '',
		draft integer not null default 0,
		created integer not null,
		updated integer not null
	)""")
	mochi.db.execute("create index if not exists requests_object on requests(object)")

def database_upgrade(version):
	if version == 2:
		mochi.db.execute("""create table if not exists subscribers (
			crm text not null references crms(id),
			id text not null,
			name text not null default '',
			subscribed integer not null,
			primary key (crm, id)
		)""")
		mochi.db.execute("create index if not exists subscribers_id on subscribers(id)")

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

# Get available crm templates from JSON files
def get_templates():
	templates = {}
	files = mochi.app.file.list("templates") or []
	for filename in files:
		if filename.endswith(".json"):
			content = mochi.app.file.read("templates/" + filename)
			if content:
				data = json.decode(str(content))
				templates[data["id"]] = {
					"id": data["id"],
					"name": data["name"],
					"description": data.get("description", ""),
					"icon": data.get("icon", ""),
					"version": data.get("version", 1),
				}
	return templates

# Apply a template to a crm by loading from JSON or from provided data
def apply_template(crm_id, data=None):
	# Load template JSON from file if no data provided
	if not data:
		content = mochi.app.file.read("templates/crm.json")
		data = json.decode(str(content))

	# Create classes
	for t in data.get("classes", []):
		mochi.db.execute(
			"insert into classes (crm, id, name, rank, requests, title) values (?, ?, ?, ?, ?, ?)",
			crm_id, t["id"], t["name"], t.get("rank", 0), t.get("requests", ""), t.get("title", "title")
		)

	# Set hierarchy for each class
	for cls_id, parents in data.get("hierarchy", {}).items():
		for parent in parents:
			mochi.db.execute(
				"insert into hierarchy (crm, class, parent) values (?, ?, ?)",
				crm_id, cls_id, parent
			)

	# Create fields for each class
	for cls_id, fields in data.get("fields", {}).items():
		for f in fields:
			mochi.db.execute(
				"insert into fields (crm, class, id, name, fieldtype, flags, multi, rank, min, max, pattern, minlength, maxlength, prefix, suffix, format, card, position, rows) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
				crm_id, cls_id, f["id"], f["name"], f.get("fieldtype", "text"),
				f.get("flags", ""), f.get("multi", 0), f.get("rank", 0),
				f.get("min", ""), f.get("max", ""), f.get("pattern", ""),
				f.get("minlength", 0), f.get("maxlength", 0),
				f.get("prefix", ""), f.get("suffix", ""), f.get("format", ""),
				f.get("card", 0), f.get("position", ""), f.get("rows", 1)
			)

	# Create options for each class's enumerated fields
	for cls_id, class_options in data.get("options", {}).items():
		for field_id, field_options in class_options.items():
			for opt in field_options:
				mochi.db.execute(
					"insert into options (crm, class, field, id, name, colour, icon, rank) values (?, ?, ?, ?, ?, ?, ?, ?)",
					crm_id, cls_id, field_id, opt["id"], opt["name"],
					opt.get("colour", "#94a3b8"), opt.get("icon", ""), opt.get("rank", 0)
				)

	# Create views
	for i, v in enumerate(data.get("views", [])):
		mochi.db.execute(
			"insert into views (crm, id, name, viewtype, filter, columns, rows, sort, direction, rank, border) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			crm_id, v["id"], v["name"], v.get("viewtype", "board"),
			v.get("filter", ""), v.get("columns", ""), v.get("rows", ""),
			v.get("sort", ""), v.get("direction", "asc"), i, v.get("border", "")
		)
		# Add view classes if specified
		for vclass in v.get("classes", []):
			mochi.db.execute(
				"insert into view_classes (crm, view, class) values (?, ?, ?)",
				crm_id, v["id"], vclass
			)
		# Add fields
		fields = v.get("fields", "").split(",")
		for j, field in enumerate(fields):
			if field.strip():
				mochi.db.execute(
					"insert into view_fields (crm, view, field, rank) values (?, ?, ?, ?)",
					crm_id, v["id"], field.strip(), j
				)


# Export the current crm design as template JSON
def action_design_export(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		a.error(400, "Cannot export remote crm design")
		return

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	# Read classes
	classes = []
	class_rows = mochi.db.rows("select id, name, rank, requests, title from classes where crm=? order by rank", crm_id) or []
	for c in class_rows:
		classes.append({
			"id": c["id"],
			"name": c["name"],
			"rank": c["rank"],
			"requests": c["requests"],
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

	result = {
		"classes": classes,
		"fields": fields,
		"options": options,
		"hierarchy": hierarchy,
		"views": views,
	}

	return {"data": result}

# Import a design from template JSON, replacing the current design
def action_design_import(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		a.error(400, "Cannot import design to remote crm")
		return

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	data_str = a.input("data")
	template_id = a.input("template") or ""
	template_version = safe_int(a.input("template_version"))

	if data_str and len(data_str) > 1000000:
		a.error(400, "Design data too large")
		return

	if len(template_id) > 100:
		a.error(400, "Template ID too long")
		return

	# Load design data from JSON string or from built-in template file
	data = None
	if data_str:
		data = json.decode(data_str)
	elif template_id:
		templates = get_templates()
		if template_id not in templates:
			a.error(400, "Invalid template")
			return
		content = mochi.app.file.read("templates/" + template_id + ".json")
		data = json.decode(str(content))
		template_version = templates[template_id]["version"]
	else:
		a.error(400, "Design data or template is required")
		return

	# Delete existing design in correct order (foreign key dependencies)
	mochi.db.execute("delete from view_fields where crm=?", crm_id)
	mochi.db.execute("delete from view_classes where crm=?", crm_id)
	mochi.db.execute("delete from views where crm=?", crm_id)
	mochi.db.execute("delete from options where crm=?", crm_id)
	mochi.db.execute("delete from fields where crm=?", crm_id)
	mochi.db.execute("delete from hierarchy where crm=?", crm_id)
	mochi.db.execute("delete from classes where crm=?", crm_id)

	# Apply the new design
	apply_template(crm_id, data)

	# Update template tracking
	mochi.db.execute(
		"update crms set template=?, template_version=? where id=?",
		template_id, template_version, crm_id
	)

	return {"data": {"success": True}}


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
	if not name or not mochi.valid(name, "name"):
		a.error(400, "Invalid name")
		return

	description = a.input("description") or ""
	privacy = a.input("privacy") or "private"

	if len(description) > 10000:
		a.error(400, "Description too long")
		return

	# Load CRM template version
	templates = get_templates()
	tmpl_version = templates.get("crm", {}).get("version", 1)

	# Create Mochi entity
	entity = mochi.entity.create("crm", name, privacy, description)
	if not entity:
		a.error(500, "Failed to create CRM entity")
		return

	now = mochi.time.now()
	creator = a.user.identity.id

	# Insert CRM record
	fp = mochi.entity.fingerprint(entity) or ""
	mochi.db.execute(
		"insert into crms (id, name, description, owner, server, fingerprint, template, template_version, created, updated) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		entity, name, description, 1, "", fp, "crm", tmpl_version, now, now
	)

	# Add creator as subscriber
	mochi.db.execute(
		"insert into subscribers (crm, id, name, subscribed) values (?, ?, ?, ?)",
		entity, creator, a.user.identity.name, now
	)

	# Apply CRM template
	apply_template(entity)

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
		a.error(400, "CRM ID required")
		return

	row = mochi.db.row("select id, name, description, owner, server, template, template_version, created, updated from crms where id=?", crm_id)
	if not row:
		a.error(404, "CRM not found")
		return

	# Get classes
	classes = mochi.db.rows("select id, name, rank, requests, title from classes where crm=? order by rank", crm_id) or []

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
			a.error(403, "Access denied")
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
				a.error(403, "Access denied")
				return
		else:
			a.error(403, "Access denied")
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
		a.error(400, "CRM ID required")
		return

	row = mochi.db.row("select id, owner from crms where id=?", crm_id)
	if not row:
		a.error(404, "CRM not found")
		return

	if row["owner"] != 1:
		a.error(403, "Cannot update remote crm")
		return

	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error(403, "Access denied")
		return

	name = a.input("name")
	description = a.input("description")

	now = mochi.time.now()

	if name:
		if not mochi.valid(name, "name"):
			a.error(400, "Invalid name")
			return
		mochi.db.execute("update crms set name=?, updated=? where id=?", name, now, crm_id)
		mochi.entity.update(crm_id, name=name)

	if a.input("description") != None:
		if len(description) > 10000:
			a.error(400, "Description too long")
			return
		mochi.db.execute("update crms set description=?, updated=? where id=?", description, now, crm_id)

	update = {"crm": crm_id}
	if name:
		update["name"] = name
	if a.input("description") != None:
		update["description"] = description
	broadcast_event(crm_id, "crm/update", update)

	return {"data": {"success": True}}

# Delete crm
def action_crm_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	row = mochi.db.row("select id, owner from crms where id=?", crm_id)
	if not row:
		a.error(404, "CRM not found")
		return

	if row["owner"] != 1:
		a.error(403, "Cannot delete remote crm")
		return

	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error(403, "Access denied")
		return

	# Delete in reverse dependency order
	delete_crm_comment_attachments(crm_id)
	for obj in (mochi.db.rows("select id from objects where crm=?", crm_id) or []):
		mochi.attachment.clear(obj["id"])
	mochi.db.execute("delete from watchers where object in (select id from objects where crm=?)", crm_id)
	mochi.db.execute("delete from activity where object in (select id from objects where crm=?)", crm_id)
	mochi.db.execute("delete from comments where object in (select id from objects where crm=?)", crm_id)
	mochi.db.execute("delete from \"values\" where object in (select id from objects where crm=?)", crm_id)
	mochi.db.execute("delete from requests where object in (select id from objects where crm=?)", crm_id)
	mochi.db.execute("delete from links where crm=?", crm_id)
	mochi.db.execute("delete from objects where crm=?", crm_id)
	mochi.db.execute("delete from view_fields where crm=?", crm_id)
	mochi.db.execute("delete from view_classes where crm=?", crm_id)
	mochi.db.execute("delete from views where crm=?", crm_id)
	mochi.db.execute("delete from options where crm=?", crm_id)
	mochi.db.execute("delete from fields where crm=?", crm_id)
	mochi.db.execute("delete from hierarchy where crm=?", crm_id)
	mochi.db.execute("delete from classes where crm=?", crm_id)
	# Notify subscribers that crm is being deleted (before removing subscriber list)
	subscribers = mochi.db.rows("select id from subscribers where crm=?", crm_id)
	for sub in subscribers:
		mochi.message.send(p2p_headers(a.user.identity.id, sub["id"], "deleted"), {"crm": crm_id})

	mochi.db.execute("delete from subscribers where crm=?", crm_id)
	mochi.db.execute("delete from crms where id=?", crm_id)

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

# Forward a subscriber action to the crm owner via P2P
def forward_to_owner(a, crm_id, action, params):
	params["_user"] = a.user.identity.id
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
		a.error(502, "Could not reach crm owner")
		return None
	if result.get("error"):
		a.error(result.get("code", 500), result["error"])
		return None
	return {"data": result}

# List access rules for a crm
def action_access_list(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	# Only owner can manage access
	if crm["owner"] != 1:
		a.error(403, "Access denied")
		return
	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error(403, "Access denied")
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
				group = mochi.db.row("select name from groups where id=?", group_id)
				rule["name"] = group["name"] if group else subject
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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	# Only owner can manage access
	if crm["owner"] != 1:
		a.error(403, "Access denied")
		return
	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error(403, "Access denied")
		return

	subject = a.input("subject")
	level = a.input("level")

	if not subject:
		a.error(400, "Subject is required")
		return
	if len(subject) > 255:
		a.error(400, "Subject too long")
		return

	if not level:
		a.error(400, "Level is required")
		return

	if level not in ["view", "comment", "write", "design", "none"]:
		a.error(400, "Invalid level")
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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	# Only owner can manage access
	if crm["owner"] != 1:
		a.error(403, "Access denied")
		return
	if not mochi.access.check(a.user.identity.id, "crm/" + crm_id, "*"):
		a.error(403, "Access denied")
		return

	subject = a.input("subject")

	if not subject:
		a.error(400, "Subject is required")
		return
	if len(subject) > 255:
		a.error(400, "Subject too long")
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
	if mochi.valid(crm_id, "fingerprint"):
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
		a.error(400, "CRM ID required")
		return None, None
	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return None, None
	if level == "view":
		if crm["owner"] == 1 and not check_crm_access(a.user.identity.id, crm_id, level):
			a.error(403, "Access denied")
			return None, None
	else:
		if not check_crm_access(a.user.identity.id, crm_id, level):
			a.error(403, "Access denied")
			return None, None
	return crm_id, crm

def log_activity(object_id, user, action, field="", oldvalue="", newvalue=""):
	"""Log an activity entry for an object."""
	activity_id = mochi.uid()
	now = mochi.time.now()
	mochi.db.execute(
		"insert into activity (id, object, user, action, field, oldvalue, newvalue, created) values (?, ?, ?, ?, ?, ?, ?, ?)",
		activity_id, object_id, user, action, field, str(oldvalue), str(newvalue), now
	)

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
	if not mochi.db.exists("select 1 from watchers where object=? and user=?", object_id, local_identity):
		return
	crm = get_crm(crm_id)
	if not crm:
		return
	obj = mochi.db.row("select class from objects where id=?", object_id)
	if not obj:
		return
	title = get_object_display(crm, obj, object_id)
	fp = mochi.entity.fingerprint(crm_id)
	url = "/crm/" + fp if fp else "/crm"
	mochi.service.call("notifications", "send", "update", title, body, object_id, url)

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
	mochi.db.execute("delete from requests where object=?", object_id)
	mochi.attachment.clear(object_id)
	mochi.db.execute("delete from watchers where object=?", object_id)
	mochi.db.execute("delete from activity where object=?", object_id)
	delete_object_comments(object_id, crm_id)
	mochi.db.execute("delete from \"values\" where object=?", object_id)
	mochi.db.execute("delete from links where source=? or target=?", object_id, object_id)
	mochi.db.execute("delete from objects where id=?", object_id)

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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	obj_class = a.input("class")
	parent = a.input("parent") or ""
	title = a.input("title") or ""

	if len(title) > 500:
		a.error(400, "Title too long")
		return

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
				now = mochi.time.now()
				mochi.db.execute(
					"insert or ignore into objects (id, crm, class, parent, rank, created, updated) values (?, ?, ?, ?, ?, ?, ?)",
					d["id"], crm_id, obj_class, parent, 0, now, now
				)
				if title and title_field:
					mochi.db.execute("insert or replace into \"values\" (object, field, value) values (?, ?, ?)", d["id"], title_field, title)
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error(403, "Access denied")
		return

	if not obj_class:
		a.error(400, "Class is required")
		return

	# Verify class exists
	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, obj_class)
	if not class_row:
		a.error(400, "Invalid class")
		return

	# Check hierarchy rules
	parent_class = ""
	if parent:
		parent_row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
		if not parent_row:
			a.error(404, "Parent object not found")
			return
		parent_class = parent_row["class"]
	allowed = mochi.db.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, obj_class, parent_class)
	if not allowed:
		a.error(400, "Cannot create here: hierarchy rules do not allow this relationship")
		return

	# Calculate initial rank (add to end)
	max_rank_row = mochi.db.row("select coalesce(max(rank), 0) as max_rank from objects where crm=?", crm_id)
	initial_rank = (max_rank_row["max_rank"] if max_rank_row else 0) + 1

	# Create object
	object_id = mochi.uid()
	now = mochi.time.now()

	mochi.db.execute(
		"insert into objects (id, crm, class, parent, rank, created, updated) values (?, ?, ?, ?, ?, ?, ?)",
		object_id, crm_id, obj_class, parent, initial_rank, now, now
	)

	# Set title if provided
	values = {}
	if title and title_field:
		mochi.db.execute("insert into \"values\" (object, field, value) values (?, ?, ?)", object_id, title_field, title)
		values[title_field] = title

	# Log activity
	log_activity(object_id, a.user.identity.id, "created")

	# Auto-watch creator
	mochi.db.execute("insert into watchers (object, user, created) values (?, ?, ?)", object_id, a.user.identity.id, now)

	# Broadcast to subscribers
	broadcast_event(crm_id, "object/create", {
		"crm": crm_id, "id": object_id, "class": obj_class,
		"parent": parent, "values": values,
		"created": now, "user": a.user.identity.id
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
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select * from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
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
		mochi.service.call("notifications", "clear.object", "crm", object_id)

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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
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
				mochi.db.execute("update objects set parent=?, updated=? where id=?", p, now, object_id)
			if c:
				mochi.db.execute("update objects set class=?, updated=? where id=?", c, now, object_id)
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error(403, "Access denied")
		return

	if not object_id:
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select * from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	now = mochi.time.now()

	# Update parent if provided
	parent = a.input("parent")
	if a.input("parent") != None:
		old_parent = row["parent"]
		if parent != old_parent:
			# Check for cycles
			if parent and would_create_cycle(object_id, parent):
				a.error(400, "Cannot set parent: would create a cycle")
				return
			# Check hierarchy rules
			if parent:
				parent_row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
				if not parent_row:
					a.error(404, "Parent object not found")
					return
				parent_class = parent_row["class"]
			else:
				parent_class = ""
			allowed = mochi.db.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, row["class"], parent_class)
			if not allowed:
				a.error(400, "Cannot set parent: hierarchy rules do not allow this relationship")
				return
			mochi.db.execute("update objects set parent=?, updated=? where id=?", parent, now, object_id)
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
						mochi.db.execute('replace into "values" (object, field, value) values (?, ?, ?)', sync_id, field_id, parent_val)

	# Update class if provided
	new_class = a.input("class")
	if new_class and new_class != row["class"]:
		# Verify class exists
		class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, new_class)
		if class_row:
			mochi.db.execute("update objects set class=?, updated=? where id=?", new_class, now, object_id)
			log_activity(object_id, a.user.identity.id, "updated", "class", row["class"], new_class)

	mochi.db.execute("update objects set updated=? where id=?", now, object_id)

	broadcast_event(crm_id, "object/update", {
		"crm": crm_id, "id": object_id,
		"parent": parent if a.input("parent") != None else row["parent"],
		"class": new_class if new_class and new_class != row["class"] else row["class"],
		"user": a.user.identity.id
	})

	return {"data": {"success": True}}

def action_object_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	object_id = a.input("object")

	if crm["owner"] != 1:
		result = forward_to_owner(a, crm_id, "object/delete", {
			"crm": crm_id, "object": object_id,
		})
		if result and object_id:
			mochi.db.execute("delete from \"values\" where object=?", object_id)
			mochi.db.execute("delete from watchers where object=?", object_id)
			delete_object_comments(object_id, crm_id)
			mochi.db.execute("delete from links where source=? or target=?", object_id, object_id)
			mochi.db.execute("delete from objects where id=?", object_id)
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error(403, "Access denied")
		return

	if not object_id:
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	# Cascade delete this object and all its children
	delete_object_cascade(crm_id, object_id, a.user.identity.id)

	return {"data": {"success": True}}

def action_object_move(a):
	"""Quick action to move object to a new status and/or rank (for drag-drop)."""

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
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
		if sp:
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
				mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, field, value)
			if rank:
				mochi.db.execute("update objects set rank=?, updated=? where id=?", int(rank), now, object_id)
			if rf:
				mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, rf, a.input("row_value"))
			if a.input("promote") == "true":
				mochi.db.execute("update objects set parent='', updated=? where id=?", now, object_id)
			mochi.db.execute("update objects set updated=? where id=?", now, object_id)
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error(403, "Access denied")
		return

	if not object_id:
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id, rank from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	old_rank = row["rank"]
	field = a.input("field") or ""
	value = a.input("value")  # New column value
	new_rank = a.input("rank")

	if field and len(field) > 100:
		a.error(400, "Field name too long")
		return

	if value and len(str(value)) > 10000:
		a.error(400, "Value too long")
		return

	# Get old field value
	old_value_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field)
	old_value = old_value_row["value"] if old_value_row else ""

	# Determine target value (use provided or keep current)
	target_value = value if value else old_value
	value_changed = old_value != target_value

	# Handle field value change
	if value_changed:
		mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, field, target_value)
		log_activity(object_id, a.user.identity.id, "updated", field, old_value, target_value)

	# Handle rank change
	scope_parent = a.input("scope_parent")
	if a.input("rank") != None:
		new_rank = int(new_rank)
		# Shift other objects to make room
		if value_changed or new_rank != old_rank:
			if scope_parent:
				# Scope renumbering to siblings of the same parent
				objects_in_scope = mochi.db.rows("""
					select o.id, o.rank from objects o
					where o.crm=? and o.parent=? and o.id!=?
					order by o.rank asc
				""", crm_id, scope_parent, object_id) or []
			else:
				# Get all objects in the target column
				objects_in_scope = mochi.db.rows("""
					select o.id, o.rank from objects o
					left join "values" v on v.object = o.id and v.field=?
					where o.crm=? and coalesce(v.value, '')=? and o.id!=?
					order by o.rank asc
				""", field, crm_id, target_value, object_id) or []

			# Renumber objects, inserting this one at the new position
			rank = 1
			for obj in objects_in_scope:
				if rank == new_rank:
					rank += 1  # Skip the position for our object
				mochi.db.execute("update objects set rank=? where id=?", rank, obj["id"])
				rank += 1

			# Set our object's rank
			mochi.db.execute("update objects set rank=? where id=?", new_rank, object_id)
	elif value_changed:
		# Moving to new column without specific rank - add to end
		max_rank_row = mochi.db.row("""
			select coalesce(max(o.rank), 0) as max_rank from objects o
			left join "values" v on v.object = o.id and v.field=?
			where o.crm=? and coalesce(v.value, '')=? and o.id!=?
		""", field, crm_id, target_value, object_id)
		new_rank = (max_rank_row["max_rank"] if max_rank_row else 0) + 1
		mochi.db.execute("update objects set rank=? where id=?", new_rank, object_id)

	# Handle row field change (for swimlane drag-drop)
	row_field = a.input("row_field")
	row_value = a.input("row_value")
	if row_value and len(str(row_value)) > 10000:
		a.error(400, "Value too long")
		return
	row_changed = False
	if row_field:
		old_row_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, row_field)
		old_row_value = old_row_row["value"] if old_row_row else ""
		if old_row_value != row_value:
			mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, row_field, row_value)
			log_activity(object_id, a.user.identity.id, "updated", row_field, old_row_value, row_value)
			row_changed = True

	# Handle promote (clear parent — for child dragged to different column/row)
	promote = a.input("promote") == "true"
	if promote:
		old_parent_row = mochi.db.row("select parent from objects where id=?", object_id)
		old_parent = old_parent_row["parent"] if old_parent_row else ""
		if old_parent:
			mochi.db.execute("update objects set parent='', updated=? where id=?", mochi.time.now(), object_id)
			log_activity(object_id, a.user.identity.id, "moved", "parent", old_parent, "")

	mochi.db.execute("update objects set updated=? where id=?", mochi.time.now(), object_id)

	# Cascade status/row changes to all descendants
	if value_changed or row_changed:
		descendants = get_all_descendants(object_id)
		now = mochi.time.now()
		for desc_id in descendants:
			if value_changed:
				mochi.db.execute('replace into "values" (object, field, value) values (?, ?, ?)', desc_id, field, target_value)
			if row_changed:
				mochi.db.execute('replace into "values" (object, field, value) values (?, ?, ?)', desc_id, row_field, row_value)
			mochi.db.execute("update objects set updated=? where id=?", now, desc_id)

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

	return {"data": {"success": True}}


# ============================================================================
# Value Actions
# ============================================================================

def action_values_set(a):
	"""Set multiple field values at once."""

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	object_id = a.input("object")
	if not object_id:
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id, class from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
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
				mochi.db.execute(
					"insert or replace into \"values\" (object, field, value) values (?, ?, ?)",
					object_id, field_id, value
				)
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error(403, "Access denied")
		return

	now = mochi.time.now()
	changes = []

	# Process each field from input
	for field_id in valid_fields:
		if a.input(field_id) == None:
			continue
		new_value = a.input(field_id)
		if len(str(new_value)) > 10000:
			a.error(400, "Value too long")
			return
		# Get old value
		old_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field_id)
		old_value = old_row["value"] if old_row else ""

		if str(new_value) != old_value:
			mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, field_id, str(new_value))
			log_activity(object_id, a.user.identity.id, "updated", field_id, old_value, str(new_value))
			changes.append(field_id)

	if changes:
		mochi.db.execute("update objects set updated=? where id=?", now, object_id)
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
					mochi.db.execute(
						"insert or ignore into watchers (object, user, created) values (?, ?, ?)",
						object_id, assigned["value"], now)

	return {"data": {"success": True, "changed": changes}}

def action_value_set(a):
	"""Set a single field value."""

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		result = forward_to_owner(a, crm_id, "value/set", {
			"crm": crm_id, "object": a.input("object"),
			"field": a.input("field"), "value": a.input("value") or "",
		})
		if result:
			# Update local cache so subsequent reads reflect the change
			mochi.db.execute(
				"insert or replace into \"values\" (object, field, value) values (?, ?, ?)",
				a.input("object"), a.input("field"), a.input("value") or ""
			)
		return result

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error(403, "Access denied")
		return

	object_id = a.input("object")
	if not object_id:
		a.error(400, "Object ID required")
		return

	field_id = a.input("field")
	if not field_id:
		a.error(400, "Field ID required")
		return

	row = mochi.db.row("select id, class from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	# Verify field exists for this class
	field_row = mochi.db.row("select id, fieldtype from fields where crm=? and class=? and id=?", crm_id, row["class"], field_id)
	if not field_row:
		a.error(400, "Invalid field for this class")
		return

	new_value = a.input("value") or ""
	if len(new_value) > 10000:
		a.error(400, "Value too long")
		return

	# Get old value
	old_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field_id)
	old_value = old_row["value"] if old_row else ""

	if str(new_value) != old_value:
		mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, field_id, str(new_value))
		now = mochi.time.now()
		mochi.db.execute("update objects set updated=? where id=?", now, object_id)
		log_activity(object_id, a.user.identity.id, "updated", field_id, old_value, str(new_value))
		broadcast_event(crm_id, "values/update", {
			"crm": crm_id, "id": object_id,
			"values": {field_id: str(new_value)}, "user": a.user.identity.id
		})
		# Auto-watch assigned user
		if field_row["fieldtype"] == "user" and str(new_value):
			mochi.db.execute(
				"insert or ignore into watchers (object, user, created) values (?, ?, ?)",
				object_id, str(new_value), now)

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
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "link/create", {
			"crm": crm_id, "object": a.input("object"),
			"target": a.input("target"), "linktype": a.input("linktype"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error(403, "Access denied")
		return

	object_id = a.input("object")
	if not object_id:
		a.error(400, "Object ID required")
		return

	target_id = a.input("target")
	if not target_id:
		a.error(400, "Target object is required")
		return

	linktype = a.input("linktype")
	if not linktype:
		a.error(400, "Link type is required")
		return

	if linktype not in ["blocks", "relates", "duplicates"]:
		a.error(400, "Invalid link type")
		return

	# Verify both objects exist in same crm
	source_row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	target_row = mochi.db.row("select id from objects where id=? and crm=?", target_id, crm_id)

	if not source_row or not target_row:
		a.error(404, "Object not found")
		return

	if object_id == target_id:
		a.error(400, "Cannot link object to itself")
		return

	# Check if link already exists
	existing = mochi.db.exists("select 1 from links where source=? and target=? and linktype=?", object_id, target_id, linktype)
	if existing:
		a.error(400, "Link already exists")
		return

	now = mochi.time.now()
	mochi.db.execute(
		"insert into links (crm, source, target, linktype, created) values (?, ?, ?, ?, ?)",
		crm_id, object_id, target_id, linktype, now
	)

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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "link/delete", {
			"crm": crm_id, "object": a.input("object"),
			"target": a.input("target"), "linktype": a.input("linktype"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error(403, "Access denied")
		return

	object_id = a.input("object")
	target_id = a.input("target")
	linktype = a.input("linktype")

	if not object_id or not target_id or not linktype:
		a.error(400, "Object, target, and linktype are required")
		return

	if linktype not in ["blocks", "relates", "duplicates"]:
		a.error(400, "Invalid link type")
		return

	mochi.db.execute("delete from links where crm=? and source=? and target=? and linktype=?", crm_id, object_id, target_id, linktype)

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
	mochi.db.execute("delete from comments where id=?", comment_id)

# Delete all comments and their attachments for an object
def delete_object_comments(object_id, crm_id):
	comments = mochi.db.rows("select id from comments where object=?", object_id) or []
	for c in comments:
		for att in (mochi.attachment.list(c["id"], crm_id) or []):
			mochi.attachment.delete(att["id"])
	mochi.db.execute("delete from comments where object=?", object_id)

# Delete all comment attachments for all objects in a crm
def delete_crm_comment_attachments(crm_id):
	comments = mochi.db.rows(
		"select c.id from comments c join objects o on c.object=o.id where o.crm=?", crm_id
	) or []
	for c in comments:
		for att in (mochi.attachment.list(c["id"], crm_id) or []):
			mochi.attachment.delete(att["id"])


# ============================================================================
# Comment Actions
# ============================================================================

def action_comment_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	comments = object_comments(crm_id, object_id, "", 0)
	count_row = mochi.db.row("select count(*) as count from comments where object=?", object_id)
	count = count_row["count"] if count_row else 0

	return {"data": {"comments": comments, "count": count}}

def action_comment_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	object_id = a.input("object")
	content = a.input("content")
	parent = a.input("parent") or ""

	if not content or not content.strip():
		a.error(400, "Content is required")
		return
	if len(content) > 50000:
		a.error(400, "Content too long")
		return

	if crm["owner"] != 1:
		if not object_id:
			a.error(400, "Object ID required")
			return
		if not mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id):
			a.error(404, "Object not found")
			return
		comment_id = mochi.uid()
		now = mochi.time.now()
		# Save locally for optimistic UI
		mochi.db.execute(
			"insert into comments (id, object, parent, author, name, content, created, edited) values (?, ?, ?, ?, ?, ?, ?, ?)",
			comment_id, object_id, parent, a.user.identity.id, a.user.identity.name, content.strip(), now, 0
		)
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
		return {"data": {
			"id": comment_id, "parent": parent,
			"author": a.user.identity.id, "name": a.user.identity.name,
			"content": content.strip(), "created": now, "edited": 0,
			"children": [], "attachments": mochi.attachment.list(comment_id, crm_id) or [],
		}}

	if not check_crm_access(a.user.identity.id, crm_id, "comment"):
		a.error(403, "Access denied")
		return

	if not object_id:
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	if not content or not content.strip():
		a.error(400, "Content is required")
		return

	if parent:
		if not mochi.db.row("select id from comments where id=? and object=?", parent, object_id):
			a.error(404, "Parent comment not found")
			return

	comment_id = mochi.uid()
	now = mochi.time.now()

	mochi.db.execute(
		"insert into comments (id, object, parent, author, name, content, created, edited) values (?, ?, ?, ?, ?, ?, ?, ?)",
		comment_id, object_id, parent, a.user.identity.id, a.user.identity.name, content.strip(), now, 0
	)

	attachments = mochi.attachment.save(comment_id, "files", [], [], []) or []

	mochi.db.execute("update objects set updated=? where id=?", now, object_id)
	log_activity(object_id, a.user.identity.id, "commented")

	# Auto-watch on comment
	mochi.db.execute(
		"insert or ignore into watchers (object, user, created) values (?, ?, ?)",
		object_id, a.user.identity.id, now)

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

	return {"data": {
		"id": comment_id, "parent": parent,
		"author": a.user.identity.id, "name": a.user.identity.name,
		"content": content.strip(), "created": now, "edited": 0,
		"children": [], "attachments": attachments,
	}}

def action_comment_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	object_id = a.input("object")
	comment_id = a.input("comment")
	content = a.input("content")

	if content and len(content) > 50000:
		a.error(400, "Content too long")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "comment/update", {
			"crm": crm_id, "object": object_id,
			"comment": comment_id, "content": content,
		})

	if not check_crm_access(a.user.identity.id, crm_id, "comment"):
		a.error(403, "Access denied")
		return

	if not object_id or not comment_id:
		a.error(400, "Object and comment ID required")
		return

	comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
	if not comment:
		a.error(404, "Comment not found")
		return

	# Only author can edit
	if comment["author"] != a.user.identity.id:
		a.error(403, "Cannot edit another user's comment")
		return

	if not content or not content.strip():
		a.error(400, "Content is required")
		return

	now = mochi.time.now()
	mochi.db.execute("update comments set content=?, edited=? where id=?", content.strip(), now, comment_id)

	broadcast_event(crm_id, "comment/update", {
		"crm": crm_id, "object": object_id,
		"id": comment_id, "content": content.strip(), "edited": now,
		"user": a.user.identity.id
	})

	return {"data": {"success": True}}

def action_comment_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	object_id = a.input("object")
	comment_id = a.input("comment")

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "comment/delete", {
			"crm": crm_id, "object": object_id,
			"comment": comment_id,
		})

	if not check_crm_access(a.user.identity.id, crm_id, "comment"):
		a.error(403, "Access denied")
		return

	if not object_id or not comment_id:
		a.error(400, "Object and comment ID required")
		return

	comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
	if not comment:
		a.error(404, "Comment not found")
		return

	# Only author can delete
	if comment["author"] != a.user.identity.id:
		a.error(403, "Cannot delete another user's comment")
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

def action_attachment_list(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	attachments = mochi.attachment.list(object_id, crm_id) or []

	return {"data": {"attachments": attachments}}

def action_attachment_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	object_id = a.input("object")
	if not object_id:
		a.error(400, "Object ID required")
		return

	if crm["owner"] != 1:
		row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
		if not row:
			a.error(404, "Object not found")
			return
		# Save locally
		attachments = mochi.attachment.save(object_id, "files", [], [], []) or []
		if not attachments:
			a.error(400, "File is required")
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
		a.error(403, "Access denied")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	now = mochi.time.now()

	# Save uploaded files locally
	attachments = mochi.attachment.save(object_id, "files", [], [], []) or []

	if not attachments:
		a.error(400, "File is required")
		return

	mochi.db.execute("update objects set updated=? where id=?", now, object_id)
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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "attachment/delete", {
			"crm": crm_id, "object": a.input("object"),
			"attachment": a.input("attachment"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "write"):
		a.error(403, "Access denied")
		return

	object_id = a.input("object")
	attachment_id = a.input("attachment")
	if not attachment_id:
		a.error(400, "Attachment ID required")
		return

	if object_id:
		if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
			a.error(404, "Object not found")
			return

	if not mochi.attachment.exists(attachment_id):
		a.error(404, "Attachment not found")
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
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
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
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
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
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	# Add current user as watcher
	now = mochi.time.now()
	mochi.db.execute(
		"insert or ignore into watchers (object, user, created) values (?, ?, ?)",
		object_id, a.user.identity.id, now
	)

	return {"data": {"success": True, "watching": True}}

def action_watcher_remove(a):

	crm_id, crm = require_crm(a)
	if not crm_id:
		return

	object_id = a.input("object")
	if not object_id:
		a.error(400, "Object ID required")
		return

	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		a.error(404, "Object not found")
		return

	# Remove current user as watcher
	mochi.db.execute("delete from watchers where object=? and user=?", object_id, a.user.identity.id)

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

	# Add fields to each view
	for v in views:
		view_fields = mochi.db.rows("select field from view_fields where crm=? and view=? order by rank", crm_id, v["id"]) or []
		v["fields"] = ",".join([vf["field"] for vf in view_fields])

	return {"data": {"views": views}}

def action_view_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
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
		a.error(403, "Access denied")
		return

	name = a.input("name")
	if not name or not name.strip():
		a.error(400, "Name is required")
		return
	if len(name) > 100:
		a.error(400, "Name too long")
		return

	viewtype = a.input("viewtype") or "board"
	if viewtype not in ["board", "list"]:
		a.error(400, "Invalid view type")
		return

	# Generate view ID from name
	view_id = name.strip().lower().replace(" ", "_")

	# Check if ID already exists
	existing = mochi.db.exists("select 1 from views where crm=? and id=?", crm_id, view_id)
	if existing:
		a.error(400, "A view with this name already exists")
		return

	filter_str = a.input("filter") or ""
	columns = a.input("columns") or ""
	if viewtype == "board" and not columns:
		a.error(400, "Columns field is required for board views")
		return
	rows = a.input("rows") or ""
	fields = a.input("fields") or "title,priority,owner,due"
	sort = a.input("sort") or ""
	direction = a.input("direction") or "asc"
	border = a.input("border") or ""

	# Assign next rank
	next_rank = mochi.db.row("select coalesce(max(rank), -1) + 1 as r from views where crm=?", crm_id)
	rank = next_rank["r"] if next_rank else 0

	mochi.db.execute(
		"insert into views (crm, id, name, viewtype, filter, columns, rows, sort, direction, rank, border) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		crm_id, view_id, name.strip(), viewtype, filter_str, columns, rows, sort, direction, rank, border
	)

	# Add fields to junction table
	for i, field in enumerate(fields.split(",")):
		if field.strip():
			mochi.db.execute(
				"insert into view_fields (crm, view, field, rank) values (?, ?, ?, ?)",
				crm_id, view_id, field.strip(), i
			)

	# Add classes to junction table
	view_classes = a.input("classes") or ""
	if view_classes:
		for cls_id in [c.strip() for c in view_classes.split(",") if c.strip()]:
			mochi.db.execute(
				"insert into view_classes (crm, view, class) values (?, ?, ?)",
				crm_id, view_id, cls_id
			)

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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		params = {"crm": crm_id, "view": a.input("view")}
		for k in ["name", "viewtype", "filter", "columns", "rows", "fields", "sort", "direction", "classes", "border"]:
			if a.input(k) != None:
				params[k] = a.input(k)
		return forward_to_owner(a, crm_id, "view/update", params)

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	view_id = a.input("view")
	if not view_id:
		a.error(400, "View ID required")
		return

	view = mochi.db.row("select * from views where crm=? and id=?", crm_id, view_id)
	if not view:
		a.error(404, "View not found")
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
		mochi.db.execute("update views set name=? where crm=? and id=?", name.strip(), crm_id, view_id)
	if a.input("viewtype") != None and viewtype != "":
		if viewtype not in ["board", "list"]:
			a.error(400, "Invalid view type")
			return
		mochi.db.execute("update views set viewtype=? where crm=? and id=?", viewtype, crm_id, view_id)
	if a.input("filter") != None:
		mochi.db.execute("update views set filter=? where crm=? and id=?", filter_str, crm_id, view_id)
	if a.input("columns") != None:
		mochi.db.execute("update views set columns=? where crm=? and id=?", columns, crm_id, view_id)
	if a.input("rows") != None:
		mochi.db.execute("update views set rows=? where crm=? and id=?", rows, crm_id, view_id)
	if a.input("fields") != None:
		# Delete existing fields and insert new ones
		mochi.db.execute("delete from view_fields where crm=? and view=?", crm_id, view_id)
		for i, field in enumerate(fields.split(",")):
			if field.strip():
				mochi.db.execute(
					"insert into view_fields (crm, view, field, rank) values (?, ?, ?, ?)",
					crm_id, view_id, field.strip(), i
				)
	if a.input("sort") != None:
		mochi.db.execute("update views set sort=? where crm=? and id=?", sort, crm_id, view_id)
	if a.input("direction") != None and direction != "":
		if direction not in ["asc", "desc"]:
			a.error(400, "Invalid direction")
			return
		mochi.db.execute("update views set direction=? where crm=? and id=?", direction, crm_id, view_id)

	border = a.input("border")
	if a.input("border") != None:
		mochi.db.execute("update views set border=? where crm=? and id=?", border, crm_id, view_id)

	# Update view classes if provided (comma-separated list of class IDs, empty string = all classes)
	view_classes_input = a.input("classes")
	if a.input("classes") != None:
		# Delete existing view classes
		mochi.db.execute("delete from view_classes where crm=? and view=?", crm_id, view_id)
		# Insert new view classes
		if view_classes_input:
			cls_ids = [c.strip() for c in view_classes_input.split(",") if c.strip()]
			for cls_id in cls_ids:
				mochi.db.execute(
					"insert into view_classes (crm, view, class) values (?, ?, ?)",
					crm_id, view_id, cls_id
				)

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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "view/delete", {
			"crm": crm_id, "view": a.input("view"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	view_id = a.input("view")
	if not view_id:
		a.error(400, "View ID required")
		return

	# Don't allow deleting the last view
	count = mochi.db.row("select count(*) as cnt from views where crm=?", crm_id)
	if count and count["cnt"] <= 1:
		a.error(400, "Cannot delete the last view")
		return

	mochi.db.execute("delete from view_fields where crm=? and view=?", crm_id, view_id)
	mochi.db.execute("delete from view_classes where crm=? and view=?", crm_id, view_id)
	mochi.db.execute("delete from views where crm=? and id=?", crm_id, view_id)

	broadcast_event(crm_id, "view/delete", {"crm": crm_id, "id": view_id})

	return {"data": {"success": True}}

def action_view_reorder(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "view/reorder", {
			"crm": crm_id, "order": a.input("order") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	# Get order (comma-separated view IDs)
	order_str = a.input("order") or ""
	order = [v.strip() for v in order_str.split(",") if v.strip()]

	# Update rank for each view
	for i, view_id in enumerate(order):
		mochi.db.execute(
			"update views set rank=? where crm=? and id=?",
			i, crm_id, view_id
		)

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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "class/create", {
			"crm": crm_id, "name": a.input("name"),
			"requests": a.input("requests") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	name = a.input("name")
	if not name or not name.strip():
		a.error(400, "Name is required")
		return
	if len(name) > 100:
		a.error(400, "Name too long")
		return

	# Generate class ID from name
	class_id = name.strip().lower().replace(" ", "_")

	# Check if ID already exists
	existing = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id)
	if existing:
		a.error(400, "A class with this name already exists")
		return

	# Get max rank
	max_rank = mochi.db.row("select max(rank) as m from classes where crm=?", crm_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0

	requests = a.input("requests") or ""

	mochi.db.execute(
		"insert into classes (crm, id, name, rank, requests, title) values (?, ?, ?, ?, ?, ?)",
		crm_id, class_id, name.strip(), rank, requests, "title"
	)

	# Add default title field
	mochi.db.execute(
		"insert into fields (crm, class, id, name, fieldtype, flags, rank) values (?, ?, ?, ?, ?, ?, ?)",
		crm_id, class_id, "title", "Title", "text", "required,sort", 0
	)

	# Set hierarchy to allow root by default
	mochi.db.execute(
		"insert into hierarchy (crm, class, parent) values (?, ?, ?)",
		crm_id, class_id, ""
	)

	broadcast_event(crm_id, "class/create", {
		"crm": crm_id, "id": class_id, "name": name.strip(), "rank": rank, "requests": requests, "title": "title"
	})

	return {"data": {"id": class_id, "name": name.strip(), "rank": rank}}

def action_class_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		params = {"crm": crm_id, "class": a.input("class")}
		n = a.input("name")
		if n:
			params["name"] = n
		req = a.input("requests")
		if req:
			params["requests"] = req
		t = a.input("title")
		if t:
			params["title"] = t
		return forward_to_owner(a, crm_id, "class/update", params)

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error(400, "Type ID required")
		return

	class_row = mochi.db.row("select * from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		a.error(404, "Class not found")
		return

	name = a.input("name")
	if name:
		mochi.db.execute("update classes set name=? where crm=? and id=?", name.strip(), crm_id, class_id)

	requests_input = a.input("requests")
	if requests_input:
		requests_value = "" if requests_input == "none" else requests_input
		mochi.db.execute("update classes set requests=? where crm=? and id=?", requests_value, crm_id, class_id)

	title_input = a.input("title")
	if title_input:
		mochi.db.execute("update classes set title=? where crm=? and id=?", title_input, crm_id, class_id)

	broadcast_event(crm_id, "class/update", {
		"crm": crm_id, "id": class_id, "name": name or class_row["name"],
		"requests": ("" if requests_input == "none" else requests_input) if requests_input else class_row["requests"],
		"title": title_input or class_row["title"]
	})

	return {"data": {"success": True}}

def action_class_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "class/delete", {
			"crm": crm_id, "class": a.input("class"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error(400, "Class ID required")
		return

	# Check if there are objects of this class
	has_objects = mochi.db.exists("select 1 from objects where crm=? and class=?", crm_id, class_id)
	if has_objects:
		a.error(400, "Cannot delete class with existing objects")
		return

	# Delete in order: options, fields, hierarchy, class
	mochi.db.execute("delete from options where crm=? and class=?", crm_id, class_id)
	mochi.db.execute("delete from fields where crm=? and class=?", crm_id, class_id)
	mochi.db.execute("delete from hierarchy where crm=? and class=?", crm_id, class_id)
	mochi.db.execute("delete from classes where crm=? and id=?", crm_id, class_id)

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
		a.error(400, "Type ID required")
		return

	parents = mochi.db.rows("select parent from hierarchy where crm=? and class=?", crm_id, class_id) or []
	parent_list = [p["parent"] for p in parents]

	return {"data": {"parents": parent_list}}

def action_hierarchy_set(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "hierarchy/set", {
			"crm": crm_id, "class": a.input("class"),
			"parents": a.input("parents"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error(400, "Type ID required")
		return

	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		a.error(404, "Type not found")
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
	mochi.db.execute("delete from hierarchy where crm=? and class=?", crm_id, class_id)

	# Insert new hierarchy entries
	for parent in parents:
		# Verify parent class exists (unless it's empty string for root)
		if parent and parent != "":
			parent_exists = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, parent)
			if not parent_exists:
				continue  # Skip invalid parents
		mochi.db.execute(
			"insert into hierarchy (crm, class, parent) values (?, ?, ?)",
			crm_id, class_id, parent
		)

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
		a.error(400, "Class ID required")
		return

	fields = mochi.db.rows(
		"select id, name, fieldtype, flags, multi, rank, min, max, pattern, minlength, maxlength, prefix, suffix, format, card, position, rows from fields where crm=? and class=? order by rank",
		crm_id, class_id
	) or []

	return {"data": {"fields": fields}}

def action_field_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "field/create", {
			"crm": crm_id, "class": a.input("class"),
			"name": a.input("name"), "fieldtype": a.input("fieldtype") or "text",
			"flags": a.input("flags") or "", "multi": a.input("multi") or "0",
			"card": a.input("card") or "1", "rows": a.input("rows") or "1",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error(400, "Type ID required")
		return

	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		a.error(404, "Type not found")
		return

	name = a.input("name")
	if not name or not name.strip():
		a.error(400, "Name is required")
		return
	if len(name) > 100:
		a.error(400, "Name too long")
		return

	fieldtype = a.input("fieldtype") or "text"
	if fieldtype not in ["text", "number", "date", "enumerated", "user", "object", "checkbox", "checklist"]:
		a.error(400, "Invalid field type")
		return

	# Generate field ID from name
	field_id = name.strip().lower().replace(" ", "_")

	# Check if ID already exists
	existing = mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if existing:
		a.error(400, "A field with this name already exists")
		return

	# Get max rank
	max_rank = mochi.db.row("select max(rank) as m from fields where crm=? and class=?", crm_id, class_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0

	flags = a.input("flags") or ""
	multi = 1 if a.input("multi") == "1" or a.input("multi") == "true" else 0
	card = 1 if a.input("card") != "0" and a.input("card") != "false" else 0
	rows = safe_int(a.input("rows"), 1)

	mochi.db.execute(
		"insert into fields (crm, class, id, name, fieldtype, flags, multi, rank, card, rows) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		crm_id, class_id, field_id, name.strip(), fieldtype, flags, multi, rank, card, rows
	)

	broadcast_event(crm_id, "field/create", {
		"crm": crm_id, "class": class_id, "id": field_id,
		"name": name.strip(), "fieldtype": fieldtype, "flags": flags,
		"multi": multi, "rank": rank, "card": card, "rows": rows
	})

	return {"data": {"id": field_id, "name": name.strip(), "fieldtype": fieldtype, "rank": rank}}

def action_field_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		params = {"crm": crm_id, "class": a.input("class"), "field": a.input("field")}
		for k in ["name", "flags", "multi", "card", "position", "rows", "id"]:
			if a.input(k) != None:
				params[k] = a.input(k)
		return forward_to_owner(a, crm_id, "field/update", params)

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	if not class_id or not field_id:
		a.error(400, "Type and field ID required")
		return

	field_row = mochi.db.row("select * from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field_row:
		a.error(404, "Field not found")
		return

	# Update fields if provided
	update_data = {"crm": crm_id, "class": class_id, "id": field_id}

	if a.input("name") != None:
		name = a.input("name").strip()
		mochi.db.execute("update fields set name=? where crm=? and class=? and id=?", name, crm_id, class_id, field_id)
		update_data["name"] = name
	if a.input("flags") != None:
		flags = a.input("flags")
		mochi.db.execute("update fields set flags=? where crm=? and class=? and id=?", flags, crm_id, class_id, field_id)
		update_data["flags"] = flags
	if a.input("multi") != None:
		multi_val = 1 if a.input("multi") in ("1", "true") else 0
		mochi.db.execute("update fields set multi=? where crm=? and class=? and id=?", multi_val, crm_id, class_id, field_id)
		update_data["multi"] = multi_val
	if a.input("card") != None:
		card_val = 1 if a.input("card") in ("1", "true") else 0
		mochi.db.execute("update fields set card=? where crm=? and class=? and id=?", card_val, crm_id, class_id, field_id)
		update_data["card"] = card_val
	if a.input("min") != None:
		min_val = a.input("min")
		mochi.db.execute("update fields set min=? where crm=? and class=? and id=?", min_val, crm_id, class_id, field_id)
		update_data["min"] = min_val
	if a.input("max") != None:
		max_val = a.input("max")
		mochi.db.execute("update fields set max=? where crm=? and class=? and id=?", max_val, crm_id, class_id, field_id)
		update_data["max"] = max_val
	if a.input("pattern") != None:
		pattern = a.input("pattern")
		mochi.db.execute("update fields set pattern=? where crm=? and class=? and id=?", pattern, crm_id, class_id, field_id)
		update_data["pattern"] = pattern
	if a.input("minlength") != None:
		minlength = safe_int(a.input("minlength"))
		mochi.db.execute("update fields set minlength=? where crm=? and class=? and id=?", minlength, crm_id, class_id, field_id)
		update_data["minlength"] = minlength
	if a.input("maxlength") != None:
		maxlength = safe_int(a.input("maxlength"))
		mochi.db.execute("update fields set maxlength=? where crm=? and class=? and id=?", maxlength, crm_id, class_id, field_id)
		update_data["maxlength"] = maxlength
	if a.input("prefix") != None:
		prefix = a.input("prefix")
		mochi.db.execute("update fields set prefix=? where crm=? and class=? and id=?", prefix, crm_id, class_id, field_id)
		update_data["prefix"] = prefix
	if a.input("suffix") != None:
		suffix = a.input("suffix")
		mochi.db.execute("update fields set suffix=? where crm=? and class=? and id=?", suffix, crm_id, class_id, field_id)
		update_data["suffix"] = suffix
	if a.input("format") != None:
		format_str = a.input("format")
		mochi.db.execute("update fields set format=? where crm=? and class=? and id=?", format_str, crm_id, class_id, field_id)
		update_data["format"] = format_str
	if a.input("position") != None:
		position = a.input("position")
		mochi.db.execute("update fields set position=? where crm=? and class=? and id=?", position, crm_id, class_id, field_id)
		update_data["position"] = position
	if a.input("rows") != None:
		rows_val = safe_int(a.input("rows"), 1)
		mochi.db.execute("update fields set rows=? where crm=? and class=? and id=?", rows_val, crm_id, class_id, field_id)
		update_data["rows"] = rows_val

	# Rename field ID if requested
	if a.input("id") != None:
		new_id = a.input("id").strip().lower()
		if not new_id:
			a.error(400, "Field ID cannot be empty")
			return
		if new_id != field_id:
			# Validate: lowercase alphanumeric + underscores only
			for ch in new_id.elems():
				if ch != "_" and not ch.isalnum():
					a.error(400, "Field ID must contain only lowercase letters, numbers, and underscores")
					return
			# Check for duplicates
			if mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, new_id):
				a.error(400, "A field with this ID already exists")
				return
			rename_field_id(crm_id, class_id, field_id, new_id)
			update_data["old_id"] = field_id
			update_data["id"] = new_id

	broadcast_event(crm_id, "field/update", update_data)

	return {"data": {"success": True}}

def action_field_delete(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "field/delete", {
			"crm": crm_id, "class": a.input("class"),
			"field": a.input("field"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	if not class_id or not field_id:
		a.error(400, "Type and field ID required")
		return

	# Delete options for this field
	mochi.db.execute("delete from options where crm=? and class=? and field=?", crm_id, class_id, field_id)

	# Delete field
	mochi.db.execute("delete from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)

	broadcast_event(crm_id, "field/delete", {"crm": crm_id, "class": class_id, "id": field_id})

	return {"data": {"success": True}}

def action_field_reorder(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "field/reorder", {
			"crm": crm_id, "class": a.input("class"),
			"order": a.input("order") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	if not class_id:
		a.error(400, "Type ID required")
		return

	# Get order (comma-separated field IDs)
	order_str = a.input("order") or ""
	order = [f.strip() for f in order_str.split(",") if f.strip()]

	# Update rank for each field
	for i, field_id in enumerate(order):
		mochi.db.execute(
			"update fields set rank=? where crm=? and class=? and id=?",
			i, crm_id, class_id, field_id
		)

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
		a.error(400, "Type and field ID required")
		return

	options = mochi.db.rows(
		"select id, name, colour, icon, rank from options where crm=? and class=? and field=? order by rank",
		crm_id, class_id, field_id
	) or []

	return {"data": {"options": options}}

def action_option_create(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "option/create", {
			"crm": crm_id, "class": a.input("class"),
			"field": a.input("field"), "name": a.input("name"),
			"colour": a.input("colour") or "#94a3b8",
			"icon": a.input("icon") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	if not class_id or not field_id:
		a.error(400, "Type and field ID required")
		return

	# Verify field exists and is enumerated
	field_row = mochi.db.row("select fieldtype from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field_row:
		a.error(404, "Field not found")
		return
	if field_row["fieldtype"] != "enumerated":
		a.error(400, "Options can only be added to enumerated fields")
		return

	name = a.input("name")
	if not name or not name.strip():
		a.error(400, "Name is required")
		return
	if len(name) > 100:
		a.error(400, "Name too long")
		return

	# Generate option ID from name
	option_id = name.strip().lower().replace(" ", "_")

	# Check if ID already exists
	existing = mochi.db.exists("select 1 from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
	if existing:
		a.error(400, "An option with this name already exists")
		return

	# Get max rank
	max_rank = mochi.db.row("select max(rank) as m from options where crm=? and class=? and field=?", crm_id, class_id, field_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0

	colour = a.input("colour") or "#94a3b8"
	if len(colour) > 20:
		a.error(400, "Colour too long")
		return
	icon = a.input("icon") or ""
	if len(icon) > 100:
		a.error(400, "Icon too long")
		return

	mochi.db.execute(
		"insert into options (crm, class, field, id, name, colour, icon, rank) values (?, ?, ?, ?, ?, ?, ?, ?)",
		crm_id, class_id, field_id, option_id, name.strip(), colour, icon, rank
	)

	broadcast_event(crm_id, "option/create", {
		"crm": crm_id, "class": class_id, "field": field_id,
		"id": option_id, "name": name.strip(), "colour": colour, "icon": icon, "rank": rank
	})

	return {"data": {"id": option_id, "name": name.strip(), "colour": colour, "rank": rank}}

def action_option_update(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		params = {"crm": crm_id, "class": a.input("class"),
				  "field": a.input("field"), "option": a.input("option")}
		for k in ["name", "colour", "icon"]:
			if a.input(k) != None:
				params[k] = a.input(k)
		return forward_to_owner(a, crm_id, "option/update", params)

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	option_id = a.input("option")
	if not class_id or not field_id or not option_id:
		a.error(400, "Type, field, and option ID required")
		return

	option_row = mochi.db.row("select * from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
	if not option_row:
		a.error(404, "Option not found")
		return

	name = a.input("name")
	colour = a.input("colour")
	icon = a.input("icon")

	if a.input("name") != None:
		if not name or not name.strip():
			a.error(400, "Name is required")
			return
		if len(name) > 100:
			a.error(400, "Name too long")
			return
		mochi.db.execute("update options set name=? where crm=? and class=? and field=? and id=?", name.strip(), crm_id, class_id, field_id, option_id)
	if a.input("colour") != None:
		if len(colour) > 20:
			a.error(400, "Colour too long")
			return
		mochi.db.execute("update options set colour=? where crm=? and class=? and field=? and id=?", colour, crm_id, class_id, field_id, option_id)
	if a.input("icon") != None:
		if len(icon) > 100:
			a.error(400, "Icon too long")
			return
		mochi.db.execute("update options set icon=? where crm=? and class=? and field=? and id=?", icon, crm_id, class_id, field_id, option_id)

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
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "option/delete", {
			"crm": crm_id, "class": a.input("class"),
			"field": a.input("field"), "option": a.input("option"),
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	option_id = a.input("option")
	if not class_id or not field_id or not option_id:
		a.error(400, "Type, field, and option ID required")
		return

	mochi.db.execute("delete from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)

	broadcast_event(crm_id, "option/delete", {"crm": crm_id, "class": class_id, "field": field_id, "id": option_id})

	return {"data": {"success": True}}

def action_option_reorder(a):

	crm_id = resolve_crm(a)
	if not crm_id:
		a.error(400, "CRM ID required")
		return

	crm = get_crm(crm_id)
	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] != 1:
		return forward_to_owner(a, crm_id, "option/reorder", {
			"crm": crm_id, "class": a.input("class"),
			"field": a.input("field"), "order": a.input("order") or "",
		})

	if not check_crm_access(a.user.identity.id, crm_id, "design"):
		a.error(403, "Access denied")
		return

	class_id = a.input("class")
	field_id = a.input("field")
	if not class_id or not field_id:
		a.error(400, "Type and field ID required")
		return

	# Get order (comma-separated option IDs)
	order_str = a.input("order") or ""
	order = [o.strip() for o in order_str.split(",") if o.strip()]

	# Update sort order for each option
	for i, option_id in enumerate(order):
		mochi.db.execute(
			"update options set rank=? where crm=? and class=? and field=? and id=?",
			i, crm_id, class_id, field_id, option_id
		)

	broadcast_event(crm_id, "option/reorder", {"crm": crm_id, "class": class_id, "field": field_id, "order": order})

	return {"data": {"success": True}}

# Search for crms in the directory
def action_search(a):
	if not a.user.identity.id:
		a.error(401, "Not logged in")
		return

	search = a.input("search")
	if not search:
		a.error(400, "No search entered")
		return
	if len(search) > 500:
		a.error(400, "Search query too long")
		return

	results = []
	all_crms = None  # Lazy-loaded for fingerprint lookups

	# Check if search term is an entity ID (49-51 word characters)
	if mochi.valid(search, "entity"):
		entry = mochi.directory.get(search)
		if entry and entry.get("class") == "crm":
			results.append(entry)

	# Check if search term is a fingerprint (9 alphanumeric, with or without hyphens)
	fingerprint = search.replace("-", "")
	if mochi.valid(fingerprint, "fingerprint"):
		# Search directory by fingerprint
		all_crms = mochi.directory.search("crm", "", False)
		for entry in all_crms:
			entry_fp = entry.get("fingerprint", "").replace("-", "")
			if entry_fp == fingerprint:
				# Avoid duplicates if already found by ID
				found = False
				for r in results:
					if r.get("id") == entry.get("id"):
						found = True
						break
				if not found:
					results.append(entry)
				break

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

			if mochi.valid(crm_id, "entity"):
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
			elif mochi.valid(crm_id, "fingerprint"):
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
	query = a.input("q", "")
	results = mochi.service.call("people", "users/search", query)
	return {"data": {"results": results}}

def action_groups(a):
	groups = mochi.service.call("people", "groups/list")
	return {"data": {"groups": groups}}


# ============================================================================
# Notification Actions
# ============================================================================

def action_notifications_subscribe(a):
	"""Create a notification subscription via the notifications service."""
	label = a.input("label", "").strip()
	type = a.input("type", "").strip()
	object = a.input("object", "").strip()
	destinations = a.input("destinations", "")

	if not label:
		a.error(400, "label is required")
		return
	if not mochi.valid(label, "text"):
		a.error(400, "Invalid label")
		return

	destinations_list = json.decode(destinations) if destinations else []

	result = mochi.service.call("notifications", "subscribe", label, type, object, destinations_list)
	return {"data": {"id": result}}

def action_notifications_check(a):
	"""Check if a notification subscription exists for this app."""
	result = mochi.service.call("notifications", "subscriptions")
	return {"data": {"exists": len(result) > 0}}

def action_notifications_destinations(a):
	"""List available notification destinations."""
	result = mochi.service.call("notifications", "destinations")
	return {"data": result}


# ============================================================================
# Remote CRMs (Subscribe/Bookmark)
# ============================================================================

# Public endpoint: resolve a crm fingerprint to basic info
# Used by remote servers to resolve fingerprints during search
# Probe a remote crm by URL without subscribing
def action_probe(a):
	if not a.user.identity.id:
		a.error(401, "Not logged in")
		return

	url = a.input("url")
	if not url:
		a.error(400, "No URL provided")
		return

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
		a.error(400, "Invalid URL format. Expected: https://server/crm/CRM_ID")
		return

	if not server or server == protocol:
		a.error(400, "Could not extract server from URL")
		return

	if not crm_id or (not mochi.valid(crm_id, "entity") and not mochi.valid(crm_id, "fingerprint")):
		a.error(400, "Could not extract valid crm ID from URL")
		return

	peer = mochi.remote.peer(server)
	if not peer:
		a.error(502, "Unable to connect to server")
		return
	response = mochi.remote.request(crm_id, "crm", "info", {"crm": crm_id}, peer)
	if response.get("error"):
		a.error(response.get("code", 404), response["error"])
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

	for item in items:
		entity_id = item.get("entity", "")
		if entity_id and entity_id not in existing_ids:
			recommendations.append({
				"id": entity_id,
				"name": item.get("name", ""),
				"blurb": item.get("blurb", ""),
				"fingerprint": mochi.entity.fingerprint(entity_id),
			})

	return {"data": {"crms": recommendations}}

# Subscribe to a remote crm
def action_subscribe(a):
	if not a.user.identity.id:
		a.error(401, "Not logged in")
		return
	user_id = a.user.identity.id

	crm_id = a.input("crm")
	server = a.input("server")
	if not mochi.valid(crm_id, "entity"):
		a.error(400, "Invalid crm ID")
		return

	# Check if already subscribed
	existing = mochi.db.row("select id, owner from crms where id=?", crm_id)
	if existing:
		if existing["owner"] == 1:
			a.error(400, "You own this crm")
			return
		# Already subscribed, just return success
		return {"data": {"fingerprint": mochi.entity.fingerprint(crm_id)}}

	# Get crm info from remote or directory
	schema = None
	if server:
		peer = mochi.remote.peer(server)
		if not peer:
			a.error(502, "Unable to connect to server")
			return
		response = mochi.remote.request(crm_id, "crm", "info", {"crm": crm_id}, peer)
		if response.get("error"):
			a.error(response.get("code", 404), response["error"])
			return
		crm_name = response.get("name", "")
		crm_desc = response.get("description", "")
		# Fetch schema so it is available before the frontend navigates
		schema = mochi.remote.request(crm_id, "crm", "schema", {}, peer)
	else:
		# Use directory lookup when no server specified
		directory = mochi.directory.get(crm_id)
		if directory == None or len(directory) == 0:
			a.error(404, "Unable to find crm in directory")
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

	# Insert the remote crm
	mochi.db.execute(
		"insert into crms (id, name, description, owner, server, fingerprint, created, updated) values (?, ?, ?, 0, ?, ?, ?, ?)",
		crm_id, crm_name, crm_desc, server or "", fp, now, now
	)

	# Insert schema so the crm page has content immediately
	if schema and not schema.get("error"):
		insert_schema(crm_id, schema)

	# Send P2P subscribe message to crm owner
	mochi.message.send(p2p_headers(user_id, crm_id, "subscribe"), {"name": a.user.identity.name})

	return {"data": {"fingerprint": fp}}

# Unsubscribe from a remote crm
def action_unsubscribe(a):
	if not a.user.identity.id:
		a.error(401, "Not logged in")
		return
	user_id = a.user.identity.id

	crm_id = a.input("crm")
	if not mochi.valid(crm_id, "entity") and not mochi.valid(crm_id, "fingerprint"):
		a.error(400, "Invalid crm ID")
		return

	# Look up by ID or fingerprint
	crm = mochi.db.row("select * from crms where id=?", crm_id)
	if not crm:
		crm = mochi.db.row("select * from crms where fingerprint=?", crm_id)
		if crm:
			crm_id = crm["id"]

	if not crm:
		a.error(404, "CRM not found")
		return

	if crm["owner"] == 1:
		a.error(400, "You own this crm")
		return

	# Delete all local data for this remote crm
	delete_crm_comment_attachments(crm_id)
	objects = mochi.db.rows("select id from objects where crm=?", crm_id)
	for obj in objects:
		mochi.db.execute("delete from watchers where object=?", obj["id"])
		mochi.db.execute("delete from activity where object=?", obj["id"])
		mochi.db.execute("delete from comments where object=?", obj["id"])
		mochi.db.execute("delete from \"values\" where object=?", obj["id"])
		mochi.db.execute("delete from links where source=? or target=?", obj["id"], obj["id"])

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
		e.stream.write({"error": "CRM not found"})
		return

	crm = mochi.db.row("select * from crms where id=?", crm_id)
	if not crm:
		e.stream.write({"error": "CRM not found"})
		return

	requester = e.header("from")
	if crm["owner"] == 1 and not check_crm_access(requester, crm_id, "view"):
		e.stream.write({"error": "Access denied"})
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
	crm = mochi.db.row("select id from crms where id=? and owner=1", crm_id)
	if not crm:
		e.stream.write({"error": "CRM not found"})
		return

	requester = e.header("from")
	if not check_crm_access(requester, crm_id, "view"):
		e.stream.write({"error": "Access denied"})
		return

	# Classes
	classes = mochi.db.rows("select id, name, rank, requests, title from classes where crm=?", crm_id) or []

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

	objects = []
	for obj in all_objects:
		if obj["id"] in values_map:
			obj["values"] = values_map[obj["id"]]
		if obj["id"] in comments_map:
			obj["comments"] = comments_map[obj["id"]]
		objects.append(obj)

	# Links
	links = mochi.db.rows("select l.source, l.target, l.linktype from links l join objects o on l.source = o.id where o.crm=?", crm_id) or []

	e.stream.write({
		"classes": classes,
		"fields": fields,
		"options": options,
		"hierarchy": hierarchy,
		"views": views,
		"objects": objects,
		"links": links,
	})

# Insert crm schema and objects into local database
def insert_schema(crm_id, schema):
	for c in (schema.get("classes") or []):
		mochi.db.execute(
			"insert or ignore into classes (id, crm, name, rank, requests, title) values (?, ?, ?, ?, ?, ?)",
			c.get("id", ""), crm_id, c.get("name", ""), c.get("rank", 0), c.get("requests", ""), c.get("title", "")
		)
	for f in (schema.get("fields") or []):
		mochi.db.execute(
			"insert or ignore into fields (crm, class, id, name, fieldtype, flags, multi, rank, card, position, rows) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			crm_id, f.get("class", ""), f.get("id", ""), f.get("name", ""),
			f.get("fieldtype", "text"), f.get("flags", ""), f.get("multi", 0),
			f.get("rank", 0), f.get("card", 1), f.get("position", ""), f.get("rows", 1)
		)
	for o in (schema.get("options") or []):
		mochi.db.execute(
			"insert or ignore into options (crm, class, field, id, name, colour, icon, rank) values (?, ?, ?, ?, ?, ?, ?, ?)",
			crm_id, o.get("class", ""), o.get("field", ""), o.get("id", ""),
			o.get("name", ""), o.get("colour", "#94a3b8"), o.get("icon", ""), o.get("rank", 0)
		)
	for h in (schema.get("hierarchy") or []):
		for parent in (h.get("parents") or []):
			mochi.db.execute(
				"insert or ignore into hierarchy (crm, class, parent) values (?, ?, ?)",
				crm_id, h.get("class", ""), parent
			)
	for v in (schema.get("views") or []):
		view_id = v.get("id", "")
		mochi.db.execute(
			"insert or ignore into views (id, crm, name, viewtype, filter, columns, rows, sort, direction, rank, border) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			view_id, crm_id, v.get("name", ""), v.get("viewtype", "board"),
			v.get("filter", ""), v.get("columns", ""), v.get("rows", ""),
			v.get("sort", ""), v.get("direction", "asc"), v.get("rank", 0),
			v.get("border", "")
		)
		fields_csv = v.get("fields", "")
		if fields_csv:
			rank = 0
			for field_id in fields_csv.split(","):
				if field_id:
					mochi.db.execute("insert or ignore into view_fields (crm, view, field, rank) values (?, ?, ?, ?)", crm_id, view_id, field_id, rank)
					rank += 1
		classes_csv = v.get("classes", "")
		if classes_csv:
			for class_id in classes_csv.split(","):
				if class_id:
					mochi.db.execute("insert or ignore into view_classes (crm, view, class) values (?, ?, ?)", crm_id, view_id, class_id)
	for obj in (schema.get("objects") or []):
		mochi.db.execute(
			"insert or ignore into objects (id, crm, class, parent, rank, created, updated) values (?, ?, ?, ?, ?, ?, ?)",
			obj.get("id", ""), crm_id, obj.get("class", ""),
			obj.get("parent", ""), obj.get("rank", 0),
			obj.get("created", 0), obj.get("updated", 0)
		)
		values = obj.get("values")
		if values:
			for field in values:
				mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", obj.get("id", ""), field, values[field])
		for c in (obj.get("comments") or []):
			mochi.db.execute(
				"insert or ignore into comments (id, object, parent, author, name, content, created, edited) values (?, ?, ?, ?, ?, ?, ?, ?)",
				c.get("id", ""), obj.get("id", ""), c.get("parent", ""),
				c.get("author", ""), c.get("name", ""),
				c.get("content", ""), c.get("created", ""), c.get("edited", 0)
			)
	for l in (schema.get("links") or []):
		mochi.db.execute(
			"insert or ignore into links (crm, source, target, linktype, created) values (?, ?, ?, ?, ?)",
			crm_id, l.get("source", ""), l.get("target", ""), l.get("linktype", ""), 0
		)

# Send all existing crm data to a new subscriber
def send_crm_data(crm_id, subscriber_id):
	h = p2p_headers(crm_id, subscriber_id, "")

	# Send classes
	types = mochi.db.rows("select * from classes where crm=?", crm_id)
	for t in types:
		h["event"] = "class/create"
		mochi.message.send(h, {"crm": crm_id, "id": t["id"], "name": t["name"], "rank": t["rank"], "requests": t["requests"], "title": t["title"]})

		# Send hierarchy for this class
		parents = mochi.db.rows("select parent from hierarchy where crm=? and class=?", crm_id, t["id"])
		if parents:
			h["event"] = "hierarchy/set"
			mochi.message.send(h, {"crm": crm_id, "class": t["id"], "parents": [p["parent"] for p in parents]})

		# Send fields for this class
		fields = mochi.db.rows("select * from fields where crm=? and class=? order by rank", crm_id, t["id"])
		for f in fields:
			h["event"] = "field/create"
			mochi.message.send(h, {
				"crm": crm_id, "class": t["id"], "id": f["id"], "name": f["name"],
				"fieldtype": f["fieldtype"], "flags": f["flags"], "multi": f["multi"],
				"rank": f["rank"], "card": f["card"], "position": f["position"], "rows": f["rows"]
			})

			# Send options for enumerated fields
			options = mochi.db.rows("select * from options where crm=? and class=? and field=? order by rank", crm_id, t["id"], f["id"])
			for o in options:
				h["event"] = "option/create"
				mochi.message.send(h, {
					"crm": crm_id, "class": t["id"], "field": f["id"],
					"id": o["id"], "name": o["name"], "colour": o["colour"], "icon": o["icon"], "rank": o["rank"]
				})

	# Send views
	views = mochi.db.rows("select * from views where crm=?", crm_id)
	for v in views:
		# Get view fields and classes
		view_fields = mochi.db.rows("select field from view_fields where crm=? and view=? order by rank", crm_id, v["id"]) or []
		fields_csv = ",".join([vf["field"] for vf in view_fields])
		view_classes = mochi.db.rows("select class from view_classes where crm=? and view=?", crm_id, v["id"]) or []
		classes_csv = ",".join([vc["class"] for vc in view_classes])
		h["event"] = "view/create"
		mochi.message.send(h, {
			"crm": crm_id, "id": v["id"], "name": v["name"], "viewtype": v["viewtype"],
			"filter": v["filter"], "columns": v["columns"], "rows": v["rows"],
			"sort": v["sort"], "direction": v["direction"], "rank": v["rank"],
			"fields": fields_csv, "classes": classes_csv, "border": v["border"]
		})

	# Send objects with their values, comments, and links
	objects = mochi.db.rows("select * from objects where crm=?", crm_id)
	for obj in objects:
		h["event"] = "object/create"
		mochi.message.send(h, {
			"crm": crm_id, "id": obj["id"], "class": obj["class"],
			"parent": obj["parent"], "rank": obj["rank"],
			"created": obj["created"], "updated": obj["updated"], "sync": True
		})

		# Send values for this object
		vals = mochi.db.rows("select field, value from \"values\" where object=?", obj["id"])
		if vals:
			values_map = {}
			for v in vals:
				values_map[v["field"]] = v["value"]
			h["event"] = "values/update"
			mochi.message.send(h, {"crm": crm_id, "id": obj["id"], "values": values_map, "sync": True})

		# Send comments for this object with attachment metadata
		comments = mochi.db.rows("select * from comments where object=? order by created", obj["id"]) or []
		for c in comments:
			h["event"] = "comment/create"
			comment_data = {
				"crm": crm_id, "id": c["id"], "object": obj["id"],
				"parent": c["parent"], "author": c["author"], "name": c["name"],
				"content": c["content"], "created": c["created"],
				"sync": True
			}
			comment_data["attachments"] = mochi.attachment.list(c["id"], crm_id) or []
			mochi.message.send(h, comment_data)

		# Send object attachments as attachment/add event
		obj_attachments = mochi.attachment.list(obj["id"], crm_id) or []
		if obj_attachments:
			h["event"] = "attachment/add"
			mochi.message.send(h, {
				"crm": crm_id, "object": obj["id"],
				"attachments": obj_attachments
			})

	# Send links (once, not per-object)
	links = mochi.db.rows("select l.source, l.target, l.linktype from links l join objects o on l.source = o.id where o.crm=?", crm_id)
	for l in links:
		h["event"] = "link/create"
		mochi.message.send(h, {"crm": crm_id, "source": l["source"], "target": l["target"], "linktype": l["linktype"], "sync": True})

# Handle subscribe event from a remote user
def event_subscribe(e):
	crm_id = e.header("to")

	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		return

	subscriber_id = e.header("from")
	if not mochi.valid(subscriber_id, "entity"):
		return

	# Check subscriber has at least view access
	if not check_crm_access(subscriber_id, crm_id, "view"):
		return

	name = e.content("name")
	if not mochi.valid(name, "line"):
		return

	now = mochi.time.now()
	mochi.db.execute(
		"insert or ignore into subscribers (crm, id, name, subscribed) values (?, ?, ?, ?)",
		crm_id, subscriber_id, name, now
	)

	# Update crm timestamp
	mochi.db.execute("update crms set updated=? where id=?", now, crm_id)

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
	mochi.db.execute("delete from watchers where user=? and object in (select id from objects where crm=?)", subscriber_id, crm_id)

	# Clean up activity records by this subscriber
	mochi.db.execute("delete from activity where user=? and object in (select id from objects where crm=?)", subscriber_id, crm_id)

	# Remove subscriber
	mochi.db.execute("delete from subscribers where crm=? and id=?", crm_id, subscriber_id)

	# Update crm timestamp
	mochi.db.execute("update crms set updated=? where id=?", mochi.time.now(), crm_id)

	# Send websocket notification
	fingerprint = mochi.entity.fingerprint(crm_id)
	if fingerprint:
		mochi.websocket.write(fingerprint, {"type": "crm/update", "crm": crm_id})

# Handle notification that a crm has been deleted by its owner
def event_deleted(e):
	crm_id = e.content("crm")
	if not crm_id:
		crm_id = e.header("from")

	# Only delete if we don't own this crm
	crm = mochi.db.row("select * from crms where id=? and owner=0", crm_id)
	if not crm:
		return

	# Delete all local data for this remote crm
	delete_crm_comment_attachments(crm_id)
	objects = mochi.db.rows("select id from objects where crm=?", crm_id)
	for obj in objects:
		mochi.db.execute("delete from watchers where object=?", obj["id"])
		mochi.db.execute("delete from activity where object=?", obj["id"])
		mochi.db.execute("delete from comments where object=?", obj["id"])
		mochi.db.execute("delete from \"values\" where object=?", obj["id"])
		mochi.db.execute("delete from links where source=? or target=?", obj["id"], obj["id"])

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


# ============================================================================
# Content Sync Event Handlers (received by subscribers)
# ============================================================================

# Helper to verify a content event is for a crm we subscribe to
def verify_subscription(e):
	crm_id = e.content("crm")
	if not crm_id:
		return None
	crm = mochi.db.row("select id from crms where id=? and owner=0", crm_id)
	if not crm:
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
		mochi.db.execute("update crms set name=? where id=?", name, crm_id)
	if description != None:
		mochi.db.execute("update crms set description=? where id=?", description, crm_id)
	mochi.db.execute("update crms set updated=? where id=?", mochi.time.now(), crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "crm/update", "crm": crm_id})

# Object created
def event_object_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	object_id = e.content("id")
	mochi.db.execute(
		"insert or ignore into objects (id, crm, class, parent, rank, created, updated) values (?, ?, ?, ?, ?, ?, ?)",
		object_id, crm_id, e.content("class") or "",
		e.content("parent") or "", e.content("rank") or 0,
		e.content("created") or mochi.time.now(), e.content("updated") or mochi.time.now()
	)
	# Store field values included in the broadcast
	values = e.content("values") or {}
	for field, value in values.items():
		mochi.db.execute("insert or replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, field, value)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "object/create", "crm": crm_id, "id": object_id})

# Object updated
def event_object_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	object_id = e.content("id")
	if not object_id:
		return
	class_id = e.content("class")
	parent = e.content("parent")
	rank = e.content("rank")
	if class_id:
		mochi.db.execute("update objects set class=? where id=? and crm=?", class_id, object_id, crm_id)
	if parent != None:
		mochi.db.execute("update objects set parent=? where id=? and crm=?", parent, object_id, crm_id)
	if rank != None:
		mochi.db.execute("update objects set rank=? where id=? and crm=?", rank, object_id, crm_id)
	mochi.db.execute("update objects set updated=? where id=? and crm=?", mochi.time.now(), object_id, crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "object/update", "crm": crm_id, "id": object_id})
	# Notify local user if watching
	if not e.content("sync"):
		user = e.content("user") or ""
		local_id = e.header("to")
		if local_id:
			notify_watchers(object_id, crm_id, local_id, user, "Updated")

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
		notify_watchers(object_id, crm_id, local_id, user, "Deleted")
	mochi.db.execute("delete from watchers where object=?", object_id)
	mochi.db.execute("delete from activity where object=?", object_id)
	delete_object_comments(object_id, crm_id)
	mochi.db.execute("delete from \"values\" where object=?", object_id)
	mochi.db.execute("delete from links where source=? or target=?", object_id, object_id)
	mochi.db.execute("delete from objects where id=? and crm=?", object_id, crm_id)
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
	for field in values:
		mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, field, values[field])
	mochi.db.execute("update objects set updated=? where id=? and crm=?", mochi.time.now(), object_id, crm_id)
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
									url = "/crm/" + fp2 if fp2 else "/crm"
									mochi.service.call("notifications", "send", "assignment",
										title, "Assigned to you",
										object_id, url)
							# Auto-watch on assignment
							mochi.db.execute(
								"insert or ignore into watchers (object, user, created) values (?, ?, ?)",
								object_id, local_id, mochi.time.now())
			if not assigned:
				notify_watchers(object_id, crm_id, local_id, user, "Fields changed")

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
	mochi.db.execute(
		"insert or ignore into comments (id, object, parent, author, name, content, created, edited) values (?, ?, ?, ?, ?, ?, ?, ?)",
		comment_id, object_id, parent, sender, name, content.strip(), now, 0
	)
	# Store attachment metadata from the subscriber's event
	attachments = e.content("attachments") or []
	if attachments:
		mochi.attachment.store(attachments, sender, comment_id)
	mochi.db.execute("update objects set updated=? where id=?", now, object_id)
	log_activity(object_id, sender, "commented")
	mochi.db.execute("insert or ignore into watchers (object, user, created) values (?, ?, ?)", object_id, sender, now)
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
	notify_watchers(object_id, crm_id, owner_id, sender, name + ": " + excerpt)

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
	mochi.db.execute("update objects set updated=? where id=?", now, object_id)
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
	mochi.db.execute(
		"insert or ignore into comments (id, object, parent, author, name, content, created, edited) values (?, ?, ?, ?, ?, ?, ?, ?)",
		comment_id, e.content("object") or "", e.content("parent") or "",
		e.content("author") or "", e.content("name") or "",
		e.content("content") or "", e.content("created") or mochi.time.now(), 0
	)
	# Store attachment metadata from the event
	attachments = e.content("attachments") or []
	if attachments:
		mochi.attachment.store(attachments, e.header("from"), comment_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "comment/create", "crm": crm_id, "object": e.content("object")})
	# Notify local user if watching
	if not e.content("sync"):
		user = e.content("user") or ""
		local_id = e.header("to")
		object_id = e.content("object")
		if object_id and local_id:
			name = e.content("name") or "Someone"
			excerpt = (e.content("content") or "")[:80]
			notify_watchers(object_id, crm_id, local_id, user, name + ": " + excerpt)

# Comment updated
def event_comment_update(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	comment_id = e.content("id")
	if not comment_id:
		return
	content = e.content("content")
	if content:
		mochi.db.execute("update comments set content=?, edited=? where id=?", content, mochi.time.now(), comment_id)
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
	mochi.db.execute(
		"insert or ignore into links (crm, source, target, linktype, created) values (?, ?, ?, ?, ?)",
		crm_id, e.content("source") or "", e.content("target") or "",
		e.content("linktype") or "related", e.content("created") or mochi.time.now()
	)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "link/create", "crm": crm_id})
	# Notify local user if watching
	if not e.content("sync"):
		user = e.content("user") or ""
		local_id = e.header("to")
		source = e.content("source")
		if source and local_id:
			notify_watchers(source, crm_id, local_id, user, "Link added")

# Link deleted
def event_link_delete(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	mochi.db.execute(
		"delete from links where source=? and target=? and linktype=?",
		e.content("source") or "", e.content("target") or "", e.content("linktype") or "related"
	)
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
	mochi.db.execute(
		"insert or ignore into views (id, crm, name, viewtype, filter, columns, rows, sort, direction, rank, border) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		view_id, crm_id, e.content("name") or "", e.content("viewtype") or "board",
		e.content("filter") or "", e.content("columns") or "", e.content("rows") or "",
		e.content("sort") or "", e.content("direction") or "asc", e.content("rank") or 0,
		e.content("border") or ""
	)
	# Sync view fields
	fields_csv = e.content("fields") or ""
	if fields_csv:
		rank = 0
		for field_id in fields_csv.split(","):
			if field_id:
				mochi.db.execute("insert or ignore into view_fields (crm, view, field, rank) values (?, ?, ?, ?)", crm_id, view_id, field_id, rank)
				rank += 1
	# Sync view classes
	classes_csv = e.content("classes") or ""
	if classes_csv:
		for class_id in classes_csv.split(","):
			if class_id:
				mochi.db.execute("insert or ignore into view_classes (crm, view, class) values (?, ?, ?)", crm_id, view_id, class_id)
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
		mochi.db.execute("update views set name=? where id=? and crm=?", name, view_id, crm_id)
	if viewtype:
		mochi.db.execute("update views set viewtype=? where id=? and crm=?", viewtype, view_id, crm_id)
	if filter_val != None:
		mochi.db.execute("update views set filter=? where id=? and crm=?", filter_val, view_id, crm_id)
	if columns != None:
		mochi.db.execute("update views set columns=? where id=? and crm=?", columns, view_id, crm_id)
	if rows != None:
		mochi.db.execute("update views set rows=? where id=? and crm=?", rows, view_id, crm_id)
	if sort != None:
		mochi.db.execute("update views set sort=? where id=? and crm=?", sort, view_id, crm_id)
	if direction != None:
		mochi.db.execute("update views set direction=? where id=? and crm=?", direction, view_id, crm_id)
	border = e.content("border")
	if border != None:
		mochi.db.execute("update views set border=? where id=? and crm=?", border, view_id, crm_id)
	# Sync view fields if provided
	fields_csv = e.content("fields")
	if fields_csv != None:
		mochi.db.execute("delete from view_fields where crm=? and view=?", crm_id, view_id)
		rank = 0
		for field_id in fields_csv.split(","):
			if field_id:
				mochi.db.execute("insert into view_fields (crm, view, field, rank) values (?, ?, ?, ?)", crm_id, view_id, field_id, rank)
				rank += 1
	# Sync view classes if provided
	classes_csv = e.content("classes")
	if classes_csv != None:
		mochi.db.execute("delete from view_classes where crm=? and view=?", crm_id, view_id)
		for class_id in classes_csv.split(","):
			if class_id:
				mochi.db.execute("insert into view_classes (crm, view, class) values (?, ?, ?)", crm_id, view_id, class_id)
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
	mochi.db.execute("delete from views where id=? and crm=?", view_id, crm_id)
	mochi.db.execute("delete from view_fields where view=? and crm=?", view_id, crm_id)
	mochi.db.execute("delete from view_classes where view=? and crm=?", view_id, crm_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "view/delete", "crm": crm_id, "id": view_id})

# Type created
def event_class_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	mochi.db.execute(
		"insert or ignore into classes (id, crm, name, rank, requests, title) values (?, ?, ?, ?, ?, ?)",
		e.content("id"), crm_id, e.content("name") or "",
		e.content("rank") or 0, e.content("requests") or "", e.content("title") or ""
	)
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
		mochi.db.execute("update classes set name=? where id=? and crm=?", name, class_id, crm_id)
	requests = e.content("requests")
	if requests != None:
		mochi.db.execute("update classes set requests=? where id=? and crm=?", requests, class_id, crm_id)
	title = e.content("title")
	if title != None:
		mochi.db.execute("update classes set title=? where id=? and crm=?", title, class_id, crm_id)
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
	mochi.db.execute("delete from options where crm=? and class=?", crm_id, class_id)
	mochi.db.execute("delete from fields where crm=? and class=?", crm_id, class_id)
	mochi.db.execute("delete from hierarchy where crm=? and class=?", crm_id, class_id)
	mochi.db.execute("delete from classes where id=? and crm=?", class_id, crm_id)
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
	mochi.db.execute("delete from hierarchy where crm=? and class=?", crm_id, class_id)
	# Insert new parents
	if parents:
		for parent in parents:
			mochi.db.execute(
				"insert into hierarchy (crm, class, parent) values (?, ?, ?)",
				crm_id, class_id, parent
			)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "hierarchy/set", "crm": crm_id, "class": class_id})

# Field created
def event_field_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	mochi.db.execute(
		"insert or ignore into fields (crm, class, id, name, fieldtype, flags, multi, rank, card, position, rows) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		crm_id, e.content("class") or "", e.content("id") or "", e.content("name") or "",
		e.content("fieldtype") or "text", e.content("flags") or "", e.content("multi") or 0,
		e.content("rank") or 0, e.content("card") or 1, e.content("position") or "", e.content("rows") or 1
	)
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
		mochi.db.execute("update fields set name=? where crm=? and class=? and id=?", name, crm_id, class_id, current_id)
	if flags != None:
		mochi.db.execute("update fields set flags=? where crm=? and class=? and id=?", flags, crm_id, class_id, current_id)
	if multi != None:
		mochi.db.execute("update fields set multi=? where crm=? and class=? and id=?", multi, crm_id, class_id, current_id)
	if card != None:
		mochi.db.execute("update fields set card=? where crm=? and class=? and id=?", card, crm_id, class_id, current_id)
	if min_val != None:
		mochi.db.execute("update fields set min=? where crm=? and class=? and id=?", min_val, crm_id, class_id, current_id)
	if max_val != None:
		mochi.db.execute("update fields set max=? where crm=? and class=? and id=?", max_val, crm_id, class_id, current_id)
	if pattern != None:
		mochi.db.execute("update fields set pattern=? where crm=? and class=? and id=?", pattern, crm_id, class_id, current_id)
	if minlength != None:
		mochi.db.execute("update fields set minlength=? where crm=? and class=? and id=?", minlength, crm_id, class_id, current_id)
	if maxlength != None:
		mochi.db.execute("update fields set maxlength=? where crm=? and class=? and id=?", maxlength, crm_id, class_id, current_id)
	if prefix != None:
		mochi.db.execute("update fields set prefix=? where crm=? and class=? and id=?", prefix, crm_id, class_id, current_id)
	if suffix != None:
		mochi.db.execute("update fields set suffix=? where crm=? and class=? and id=?", suffix, crm_id, class_id, current_id)
	if format_str != None:
		mochi.db.execute("update fields set format=? where crm=? and class=? and id=?", format_str, crm_id, class_id, current_id)
	if position != None:
		mochi.db.execute("update fields set position=? where crm=? and class=? and id=?", position, crm_id, class_id, current_id)
	if rows_val != None:
		mochi.db.execute("update fields set rows=? where crm=? and class=? and id=?", rows_val, crm_id, class_id, current_id)
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
	mochi.db.execute("delete from options where crm=? and class=? and field=?", crm_id, class_id, field_id)
	mochi.db.execute("delete from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
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
		mochi.db.execute("update fields set rank=? where crm=? and class=? and id=?", i, crm_id, class_id, field_id)
	fp = mochi.entity.fingerprint(crm_id)
	if fp:
		mochi.websocket.write(fp, {"type": "field/reorder", "crm": crm_id, "class_id": class_id})

# Option created
def event_option_create(e):
	crm_id = verify_subscription(e)
	if not crm_id:
		return
	mochi.db.execute(
		"insert or ignore into options (crm, class, field, id, name, colour, icon, rank) values (?, ?, ?, ?, ?, ?, ?, ?)",
		crm_id, e.content("class") or "", e.content("field") or "", e.content("id") or "",
		e.content("name") or "", e.content("colour") or "#94a3b8", e.content("icon") or "",
		e.content("rank") or 0
	)
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
		mochi.db.execute("update options set name=? where crm=? and class=? and field=? and id=?", name, crm_id, class_id, field_id, option_id)
	if colour != None:
		mochi.db.execute("update options set colour=? where crm=? and class=? and field=? and id=?", colour, crm_id, class_id, field_id, option_id)
	if icon != None:
		mochi.db.execute("update options set icon=? where crm=? and class=? and field=? and id=?", icon, crm_id, class_id, field_id, option_id)
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
	mochi.db.execute("delete from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
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
		mochi.db.execute("update options set rank=? where crm=? and class=? and field=? and id=?", i, crm_id, class_id, field_id, option_id)
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
	user_id = params.get("_user", requester)
	user_name = params.get("_name", "")

	crm_id = params.get("crm")
	if not crm_id:
		e.stream.write({"error": "CRM required", "code": 400})
		return

	crm = mochi.db.row("select * from crms where id=? and owner=1", crm_id)
	if not crm:
		e.stream.write({"error": "CRM not found", "code": 404})
		return

	level = REQUEST_LEVELS.get(action)
	if not level:
		e.stream.write({"error": "Unknown action", "code": 400})
		return

	if not check_crm_access(requester, crm_id, level):
		e.stream.write({"error": "Access denied", "code": 403})
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
		result = {"error": "Not implemented", "code": 501}

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
		return {"error": "Object not found", "code": 404}
	if not content or not content.strip():
		return {"error": "Content is required", "code": 400}
	comment_id = params.get("id") or mochi.uid()
	now = mochi.time.now()
	mochi.db.execute(
		"insert or ignore into comments (id, object, parent, author, name, content, created, edited) values (?, ?, ?, ?, ?, ?, ?, ?)",
		comment_id, object_id, parent, user_id, user_name, content.strip(), now, 0
	)
	mochi.db.execute("update objects set updated=? where id=?", now, object_id)
	log_activity(object_id, user_id, "commented")
	# Auto-watch commenter on owner's server
	mochi.db.execute(
		"insert or ignore into watchers (object, user, created) values (?, ?, ?)",
		object_id, user_id, now)
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
	notify_watchers(object_id, crm_id, owner_id, user_id, user_name + ": " + excerpt)
	return {"id": comment_id, "author": user_id, "name": user_name,
			"content": content.strip(), "created": now}

def do_comment_update(crm_id, crm, params, user_id):
	object_id = params.get("object")
	comment_id = params.get("comment")
	content = params.get("content")
	if not object_id or not comment_id:
		return {"error": "Object and comment ID required", "code": 400}
	comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
	if not comment:
		return {"error": "Comment not found", "code": 404}
	if comment["author"] != user_id:
		return {"error": "Cannot edit another user's comment", "code": 403}
	if not content or not content.strip():
		return {"error": "Content is required", "code": 400}
	now = mochi.time.now()
	mochi.db.execute("update comments set content=?, edited=? where id=?", content.strip(), now, comment_id)
	broadcast_event(crm_id, "comment/update", {
		"crm": crm_id, "object": object_id,
		"id": comment_id, "content": content.strip(), "edited": now, "user": user_id
	})
	return {"success": True}

def do_comment_delete(crm_id, crm, params, user_id):
	object_id = params.get("object")
	comment_id = params.get("comment")
	if not object_id or not comment_id:
		return {"error": "Object and comment ID required", "code": 400}
	comment = mochi.db.row("select * from comments where id=? and object=?", comment_id, object_id)
	if not comment:
		return {"error": "Comment not found", "code": 404}
	if comment["author"] != user_id:
		return {"error": "Cannot delete another user's comment", "code": 403}
	delete_comment_tree(comment_id, crm_id)
	broadcast_event(crm_id, "comment/delete", {
		"crm": crm_id, "object": object_id, "id": comment_id, "user": user_id
	})
	return {"success": True}

# Watcher helpers
def do_watcher_add(crm_id, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "Object ID required", "code": 400}
	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "Object not found", "code": 404}
	now = mochi.time.now()
	mochi.db.execute(
		"insert or ignore into watchers (object, user, created) values (?, ?, ?)",
		object_id, user_id, now
	)
	return {"success": True, "watching": True}

def do_watcher_remove(crm_id, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "Object ID required", "code": 400}
	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "Object not found", "code": 404}
	mochi.db.execute("delete from watchers where object=? and user=?", object_id, user_id)
	return {"success": True, "watching": False}

# Object helpers
def do_object_create(crm_id, crm, params, user_id):
	obj_class = params.get("class")
	if not obj_class:
		return {"error": "Class is required", "code": 400}
	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, obj_class)
	if not class_row:
		return {"error": "Invalid class", "code": 400}
	parent = params.get("parent", "")
	title = params.get("title", "")

	# Check hierarchy rules
	parent_class = ""
	if parent:
		parent_row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
		if not parent_row:
			return {"error": "Parent object not found", "code": 404}
		parent_class = parent_row["class"]
	allowed = mochi.db.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, obj_class, parent_class)
	if not allowed:
		return {"error": "Cannot create here: hierarchy rules do not allow this relationship", "code": 400}

	title_field_row = mochi.db.row("select title from classes where crm=? and id=?", crm_id, obj_class)
	title_field = title_field_row["title"] if title_field_row else ""
	max_rank_row = mochi.db.row("select coalesce(max(rank), 0) as max_rank from objects where crm=?", crm_id)
	initial_rank = (max_rank_row["max_rank"] if max_rank_row else 0) + 1
	object_id = mochi.uid()
	now = mochi.time.now()
	mochi.db.execute(
		"insert into objects (id, crm, class, parent, rank, created, updated) values (?, ?, ?, ?, ?, ?, ?)",
		object_id, crm_id, obj_class, parent, initial_rank, now, now
	)
	values = {}
	if title and title_field:
		mochi.db.execute("insert into \"values\" (object, field, value) values (?, ?, ?)", object_id, title_field, title)
		values[title_field] = title
	log_activity(object_id, user_id, "created")
	mochi.db.execute("insert into watchers (object, user, created) values (?, ?, ?)", object_id, user_id, now)
	broadcast_event(crm_id, "object/create", {
		"crm": crm_id, "id": object_id, "class": obj_class,
		"parent": parent, "values": values,
		"created": now, "user": user_id
	})
	# Notify owner when subscriber creates an object
	owner_id = get_owner_identity(crm_id)
	if owner_id and owner_id != user_id:
		obj = mochi.db.row("select class from objects where id=?", object_id)
		display = get_object_display(crm, obj, object_id)
		fp = mochi.entity.fingerprint(crm_id)
		url = "/crm/" + fp if fp else "/crm"
		mochi.service.call("notifications", "send", "update",
			display, "Created", object_id, url)
	return {"id": object_id}

def do_object_update(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "Object ID required", "code": 400}
	row = mochi.db.row("select * from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "Object not found", "code": 404}
	now = mochi.time.now()
	parent = params.get("parent")
	if parent != None:
		old_parent = row["parent"]
		if parent != old_parent:
			if parent and would_create_cycle(object_id, parent):
				return {"error": "Cannot set parent: would create a cycle", "code": 400}
			if parent:
				parent_row = mochi.db.row("select class from objects where id=? and crm=?", parent, crm_id)
				if not parent_row:
					return {"error": "Parent object not found", "code": 404}
				parent_class = parent_row["class"]
			else:
				parent_class = ""
			allowed = mochi.db.exists("select 1 from hierarchy where crm=? and class=? and parent=?", crm_id, row["class"], parent_class)
			if not allowed:
				return {"error": "Cannot set parent: hierarchy rules do not allow this relationship", "code": 400}
			mochi.db.execute("update objects set parent=?, updated=? where id=?", parent, now, object_id)
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
						mochi.db.execute('replace into "values" (object, field, value) values (?, ?, ?)', sync_id, field_id, parent_val)

	new_class = params.get("class")
	if new_class and new_class != row["class"]:
		class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, new_class)
		if class_row:
			mochi.db.execute("update objects set class=?, updated=? where id=?", new_class, now, object_id)
			log_activity(object_id, user_id, "updated", "class", row["class"], new_class)
	mochi.db.execute("update objects set updated=? where id=?", now, object_id)
	broadcast_event(crm_id, "object/update", {
		"crm": crm_id, "id": object_id,
		"parent": parent if parent != None else row["parent"],
		"class": new_class if new_class and new_class != row["class"] else row["class"],
		"user": user_id
	})
	# Notify owner if watching
	owner_id = get_owner_identity(crm_id)
	notify_watchers(object_id, crm_id, owner_id, user_id, "Updated")
	return {"success": True}

def do_object_delete(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "Object ID required", "code": 400}
	row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "Object not found", "code": 404}
	# Notify owner before cascade (watchers get deleted in cascade)
	owner_id = get_owner_identity(crm_id)
	notify_watchers(object_id, crm_id, owner_id, user_id, "Deleted")
	delete_object_cascade(crm_id, object_id, user_id)
	return {"success": True}

def do_object_move(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "Object ID required", "code": 400}
	row = mochi.db.row("select id, rank from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "Object not found", "code": 404}
	old_rank = row["rank"]
	field = params.get("field", "")
	value = params.get("value")
	new_rank = params.get("rank")
	old_value_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field)
	old_value = old_value_row["value"] if old_value_row else ""
	target_value = value if value else old_value
	value_changed = old_value != target_value
	if value_changed:
		mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, field, target_value)
		log_activity(object_id, user_id, "updated", field, old_value, target_value)
	scope_parent = params.get("scope_parent", "")
	if new_rank != None:
		new_rank = int(new_rank)
		if value_changed or new_rank != old_rank:
			if scope_parent:
				objects_in_scope = mochi.db.rows("""
					select o.id, o.rank from objects o
					where o.crm=? and o.parent=? and o.id!=?
					order by o.rank asc
				""", crm_id, scope_parent, object_id) or []
			else:
				objects_in_scope = mochi.db.rows("""
					select o.id, o.rank from objects o
					left join "values" v on v.object = o.id and v.field=?
					where o.crm=? and coalesce(v.value, '')=? and o.id!=?
					order by o.rank asc
				""", field, crm_id, target_value, object_id) or []
			rank = 1
			for obj in objects_in_scope:
				if rank == new_rank:
					rank += 1
				mochi.db.execute("update objects set rank=? where id=?", rank, obj["id"])
				rank += 1
			mochi.db.execute("update objects set rank=? where id=?", new_rank, object_id)
	elif value_changed:
		max_rank_row = mochi.db.row("""
			select coalesce(max(o.rank), 0) as max_rank from objects o
			left join "values" v on v.object = o.id and v.field=?
			where o.crm=? and coalesce(v.value, '')=? and o.id!=?
		""", field, crm_id, target_value, object_id)
		new_rank = (max_rank_row["max_rank"] if max_rank_row else 0) + 1
		mochi.db.execute("update objects set rank=? where id=?", new_rank, object_id)
	row_field = params.get("row_field")
	row_value = params.get("row_value")
	row_changed = False
	if row_field:
		old_row_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, row_field)
		old_row_value = old_row_row["value"] if old_row_row else ""
		if old_row_value != row_value:
			mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, row_field, row_value)
			log_activity(object_id, user_id, "updated", row_field, old_row_value, row_value)
			row_changed = True

	# Handle promote (clear parent)
	promote = params.get("promote", "") == "true"
	if promote:
		old_parent_row = mochi.db.row("select parent from objects where id=?", object_id)
		old_parent = old_parent_row["parent"] if old_parent_row else ""
		if old_parent:
			mochi.db.execute("update objects set parent='', updated=? where id=?", mochi.time.now(), object_id)
			log_activity(object_id, user_id, "moved", "parent", old_parent, "")

	mochi.db.execute("update objects set updated=? where id=?", mochi.time.now(), object_id)

	# Cascade status/row changes to all descendants
	if value_changed or row_changed:
		descendants = get_all_descendants(object_id)
		now = mochi.time.now()
		for desc_id in descendants:
			if value_changed:
				mochi.db.execute('replace into "values" (object, field, value) values (?, ?, ?)', desc_id, field, target_value)
			if row_changed:
				mochi.db.execute('replace into "values" (object, field, value) values (?, ?, ?)', desc_id, row_field, row_value)
			mochi.db.execute("update objects set updated=? where id=?", now, desc_id)

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
		notify_watchers(object_id, crm_id, owner_id, user_id, "Fields changed")

	# Broadcast rank changes to subscribers
	if new_rank != None:
		if scope_parent:
			all_in_scope = mochi.db.rows("select id, rank from objects where crm=? and parent=? order by rank asc", crm_id, scope_parent) or []
		else:
			all_in_scope = mochi.db.rows("""
				select o.id, o.rank from objects o
				left join "values" v on v.object = o.id and v.field=?
				where o.crm=? and coalesce(v.value, '')=?
				order by o.rank asc
			""", field, crm_id, target_value) or []
		for obj in all_in_scope:
			broadcast_event(crm_id, "object/update", {
				"crm": crm_id, "id": obj["id"], "rank": obj["rank"], "user": user_id
			})

	return {"success": True}

# Value helpers
def do_values_set(crm_id, crm, params, user_id):
	object_id = params.get("object")
	if not object_id:
		return {"error": "Object ID required", "code": 400}
	row = mochi.db.row("select id, class from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "Object not found", "code": 404}
	valid_fields = {}
	field_types = {}
	field_rows = mochi.db.rows("select id, name, fieldtype from fields where crm=? and class=?", crm_id, row["class"]) or []
	for f in field_rows:
		valid_fields[f["id"]] = f["name"]
		field_types[f["id"]] = f["fieldtype"]
	now = mochi.time.now()
	changes = []
	values = params.get("values", {})
	for field_id in values:
		if field_id not in valid_fields:
			continue
		new_value = values[field_id]
		old_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field_id)
		old_value = old_row["value"] if old_row else ""
		if str(new_value) != old_value:
			mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, field_id, str(new_value))
			log_activity(object_id, user_id, "updated", field_id, old_value, str(new_value))
			changes.append(field_id)
	if changes:
		mochi.db.execute("update objects set updated=? where id=?", now, object_id)
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
		notify_watchers(object_id, crm_id, owner_id, user_id, "Fields changed")
		# Auto-watch assigned users
		for fid in changes:
			if field_types.get(fid) == "user":
				assigned = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, fid)
				if assigned and assigned["value"]:
					mochi.db.execute(
						"insert or ignore into watchers (object, user, created) values (?, ?, ?)",
						object_id, assigned["value"], now)
	return {"success": True, "changed": changes}

def do_value_set(crm_id, crm, params, user_id):
	object_id = params.get("object")
	field_id = params.get("field")
	if not object_id:
		return {"error": "Object ID required", "code": 400}
	if not field_id:
		return {"error": "Field ID required", "code": 400}
	row = mochi.db.row("select id, class from objects where id=? and crm=?", object_id, crm_id)
	if not row:
		return {"error": "Object not found", "code": 404}
	field_row = mochi.db.row("select id, fieldtype from fields where crm=? and class=? and id=?", crm_id, row["class"], field_id)
	if not field_row:
		return {"error": "Invalid field for this class", "code": 400}
	new_value = params.get("value", "")
	old_row = mochi.db.row("select value from \"values\" where object=? and field=?", object_id, field_id)
	old_value = old_row["value"] if old_row else ""
	if str(new_value) != old_value:
		mochi.db.execute("replace into \"values\" (object, field, value) values (?, ?, ?)", object_id, field_id, str(new_value))
		now = mochi.time.now()
		mochi.db.execute("update objects set updated=? where id=?", now, object_id)
		log_activity(object_id, user_id, "updated", field_id, old_value, str(new_value))
		broadcast_event(crm_id, "values/update", {
			"crm": crm_id, "id": object_id,
			"values": {field_id: str(new_value)}, "user": user_id
		})
		# Notify owner if watching
		owner_id = get_owner_identity(crm_id)
		notify_watchers(object_id, crm_id, owner_id, user_id, "Fields changed")
		# Auto-watch assigned user
		if field_row["fieldtype"] == "user" and str(new_value):
			mochi.db.execute(
				"insert or ignore into watchers (object, user, created) values (?, ?, ?)",
				object_id, str(new_value), now)
	return {"success": True}

# Link helpers
def do_link_create(crm_id, crm, params, user_id):
	object_id = params.get("object")
	target_id = params.get("target")
	linktype = params.get("linktype")
	if not object_id or not target_id or not linktype:
		return {"error": "Object, target, and linktype are required", "code": 400}
	if linktype not in ["blocks", "relates", "duplicates"]:
		return {"error": "Invalid link type", "code": 400}
	source_row = mochi.db.row("select id from objects where id=? and crm=?", object_id, crm_id)
	target_row = mochi.db.row("select id from objects where id=? and crm=?", target_id, crm_id)
	if not source_row or not target_row:
		return {"error": "Object not found", "code": 404}
	if object_id == target_id:
		return {"error": "Cannot link object to itself", "code": 400}
	existing = mochi.db.exists("select 1 from links where source=? and target=? and linktype=?", object_id, target_id, linktype)
	if existing:
		return {"error": "Link already exists", "code": 400}
	now = mochi.time.now()
	mochi.db.execute(
		"insert into links (crm, source, target, linktype, created) values (?, ?, ?, ?, ?)",
		crm_id, object_id, target_id, linktype, now
	)
	log_activity(object_id, user_id, "linked", linktype, "", target_id)
	broadcast_event(crm_id, "link/create", {
		"crm": crm_id, "source": object_id,
		"target": target_id, "linktype": linktype, "created": now, "user": user_id
	})
	# Notify owner if watching
	owner_id = get_owner_identity(crm_id)
	notify_watchers(object_id, crm_id, owner_id, user_id, "Link added")
	return {"success": True}

def do_link_delete(crm_id, crm, params, user_id):
	object_id = params.get("object")
	target_id = params.get("target")
	linktype = params.get("linktype")
	if not object_id or not target_id or not linktype:
		return {"error": "Object, target, and linktype are required", "code": 400}
	mochi.db.execute("delete from links where crm=? and source=? and target=? and linktype=?", crm_id, object_id, target_id, linktype)
	broadcast_event(crm_id, "link/delete", {
		"crm": crm_id, "source": object_id,
		"target": target_id, "linktype": linktype, "user": user_id
	})
	# Notify owner if watching
	owner_id = get_owner_identity(crm_id)
	notify_watchers(object_id, crm_id, owner_id, user_id, "Link removed")
	return {"success": True}

# Attachment helper
def do_attachment_delete(crm_id, crm, params, user_id):
	attachment_id = params.get("attachment")
	object_id = params.get("object")
	if not attachment_id:
		return {"error": "Attachment ID required", "code": 400}
	if object_id:
		if not mochi.db.exists("select 1 from objects where id=? and crm=?", object_id, crm_id):
			return {"error": "Object not found", "code": 404}
	if not mochi.attachment.exists(attachment_id):
		return {"error": "Attachment not found", "code": 404}
	mochi.attachment.delete(attachment_id, [])
	broadcast_event(crm_id, "attachment/remove", {
		"crm": crm_id, "attachment": attachment_id
	})
	return {"success": True}

# Class helpers
def do_class_create(crm_id, crm, params):
	name = params.get("name")
	if not name or not name.strip():
		return {"error": "Name is required", "code": 400}
	class_id = name.strip().lower().replace(" ", "_")
	existing = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, class_id)
	if existing:
		return {"error": "A class with this name already exists", "code": 400}
	max_rank = mochi.db.row("select max(rank) as m from classes where crm=?", crm_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0
	requests = params.get("requests", "")
	mochi.db.execute(
		"insert into classes (crm, id, name, rank, requests, title) values (?, ?, ?, ?, ?, ?)",
		crm_id, class_id, name.strip(), rank, requests, "title"
	)
	mochi.db.execute(
		"insert into fields (crm, class, id, name, fieldtype, flags, rank) values (?, ?, ?, ?, ?, ?, ?)",
		crm_id, class_id, "title", "Title", "text", "required,sort", 0
	)
	mochi.db.execute(
		"insert into hierarchy (crm, class, parent) values (?, ?, ?)",
		crm_id, class_id, ""
	)
	broadcast_event(crm_id, "class/create", {
		"crm": crm_id, "id": class_id, "name": name.strip(), "rank": rank, "requests": requests, "title": "title"
	})
	return {"id": class_id, "name": name.strip(), "rank": rank}

def do_class_update(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "Type ID required", "code": 400}
	class_row = mochi.db.row("select * from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		return {"error": "Class not found", "code": 404}
	name = params.get("name")
	if name:
		mochi.db.execute("update classes set name=? where crm=? and id=?", name.strip(), crm_id, class_id)
	requests_input = params.get("requests")
	if requests_input:
		requests_value = "" if requests_input == "none" else requests_input
		mochi.db.execute("update classes set requests=? where crm=? and id=?", requests_value, crm_id, class_id)
	title_input = params.get("title")
	if title_input:
		mochi.db.execute("update classes set title=? where crm=? and id=?", title_input, crm_id, class_id)
	broadcast_event(crm_id, "class/update", {
		"crm": crm_id, "id": class_id, "name": name or class_row["name"],
		"requests": ("" if requests_input == "none" else requests_input) if requests_input else class_row["requests"],
		"title": title_input or class_row["title"]
	})
	return {"success": True}

def do_class_delete(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "Class ID required", "code": 400}
	has_objects = mochi.db.exists("select 1 from objects where crm=? and class=?", crm_id, class_id)
	if has_objects:
		return {"error": "Cannot delete class with existing objects", "code": 400}
	mochi.db.execute("delete from options where crm=? and class=?", crm_id, class_id)
	mochi.db.execute("delete from fields where crm=? and class=?", crm_id, class_id)
	mochi.db.execute("delete from hierarchy where crm=? and class=?", crm_id, class_id)
	mochi.db.execute("delete from classes where crm=? and id=?", crm_id, class_id)
	broadcast_event(crm_id, "class/delete", {"crm": crm_id, "id": class_id})
	return {"success": True}

# Field helpers
def do_field_create(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "Type ID required", "code": 400}
	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		return {"error": "Type not found", "code": 404}
	name = params.get("name")
	if not name or not name.strip():
		return {"error": "Name is required", "code": 400}
	fieldtype = params.get("fieldtype", "text")
	if fieldtype not in ["text", "number", "date", "enumerated", "user", "object", "checkbox", "checklist"]:
		return {"error": "Invalid field type", "code": 400}
	field_id = name.strip().lower().replace(" ", "_")
	existing = mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if existing:
		return {"error": "A field with this name already exists", "code": 400}
	max_rank = mochi.db.row("select max(rank) as m from fields where crm=? and class=?", crm_id, class_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0
	flags = params.get("flags", "")
	multi = 1 if params.get("multi") == "1" or params.get("multi") == "true" else 0
	card = 1 if params.get("card") != "0" and params.get("card") != "false" else 0
	rows = safe_int(params.get("rows"), 1)
	mochi.db.execute(
		"insert into fields (crm, class, id, name, fieldtype, flags, multi, rank, card, rows) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		crm_id, class_id, field_id, name.strip(), fieldtype, flags, multi, rank, card, rows
	)
	broadcast_event(crm_id, "field/create", {
		"crm": crm_id, "class": class_id, "id": field_id,
		"name": name.strip(), "fieldtype": fieldtype, "flags": flags,
		"multi": multi, "rank": rank, "card": card, "rows": rows
	})
	return {"id": field_id, "name": name.strip(), "fieldtype": fieldtype, "rank": rank}

# Rename a field ID across all tables that reference it
def rename_field_id(crm_id, class_id, old_id, new_id):
	mochi.db.execute("update fields set id=? where crm=? and class=? and id=?", new_id, crm_id, class_id, old_id)
	mochi.db.execute("update options set field=? where crm=? and class=? and field=?", new_id, crm_id, class_id, old_id)
	# Delete orphaned values that already use the new field id to avoid unique constraint violations
	mochi.db.execute('delete from "values" where field=? and object in (select id from objects where crm=? and class=?) and object in (select object from "values" where field=?)', new_id, crm_id, class_id, old_id)
	mochi.db.execute('update "values" set field=? where field=? and object in (select id from objects where crm=? and class=?)', new_id, old_id, crm_id, class_id)
	mochi.db.execute("update view_fields set field=? where crm=? and field=?", new_id, crm_id, old_id)
	mochi.db.execute("update activity set field=? where field=? and object in (select id from objects where crm=? and class=?)", new_id, old_id, crm_id, class_id)
	mochi.db.execute("update views set columns=? where crm=? and columns=?", new_id, crm_id, old_id)
	mochi.db.execute("update views set rows=? where crm=? and rows=?", new_id, crm_id, old_id)
	mochi.db.execute("update views set sort=? where crm=? and sort=?", new_id, crm_id, old_id)
	mochi.db.execute("update views set border=? where crm=? and border=?", new_id, crm_id, old_id)
	mochi.db.execute("update classes set title=? where crm=? and id=? and title=?", new_id, crm_id, class_id, old_id)

def do_field_update(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	if not class_id or not field_id:
		return {"error": "Type and field ID required", "code": 400}
	field_row = mochi.db.row("select * from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field_row:
		return {"error": "Field not found", "code": 404}
	name = params.get("name")
	flags = params.get("flags")
	multi = params.get("multi")
	card = params.get("card")
	position = params.get("position")
	rows_val = params.get("rows")
	if name != None:
		mochi.db.execute("update fields set name=? where crm=? and class=? and id=?", name.strip(), crm_id, class_id, field_id)
	if flags != None:
		mochi.db.execute("update fields set flags=? where crm=? and class=? and id=?", flags, crm_id, class_id, field_id)
	if multi != None:
		multi_val = 1 if multi == "1" or multi == "true" else 0
		mochi.db.execute("update fields set multi=? where crm=? and class=? and id=?", multi_val, crm_id, class_id, field_id)
	if card != None:
		card_val = 1 if card == "1" or card == "true" else 0
		mochi.db.execute("update fields set card=? where crm=? and class=? and id=?", card_val, crm_id, class_id, field_id)
	if position != None:
		mochi.db.execute("update fields set position=? where crm=? and class=? and id=?", position, crm_id, class_id, field_id)
	if rows_val != None:
		mochi.db.execute("update fields set rows=? where crm=? and class=? and id=?", int(rows_val), crm_id, class_id, field_id)
	# Rename field ID if requested
	new_id = params.get("id")
	if new_id != None:
		new_id = new_id.strip().lower()
		if new_id and new_id != field_id:
			for ch in new_id.elems():
				if ch != "_" and not ch.isalnum():
					return {"error": "Field ID must contain only lowercase letters, numbers, and underscores", "code": 400}
			if mochi.db.exists("select 1 from fields where crm=? and class=? and id=?", crm_id, class_id, new_id):
				return {"error": "A field with this ID already exists", "code": 400}
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
		return {"error": "Type and field ID required", "code": 400}
	mochi.db.execute("delete from options where crm=? and class=? and field=?", crm_id, class_id, field_id)
	mochi.db.execute("delete from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	broadcast_event(crm_id, "field/delete", {"crm": crm_id, "class": class_id, "id": field_id})
	return {"success": True}

def do_field_reorder(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "Type ID required", "code": 400}
	order_str = params.get("order", "")
	order = [f.strip() for f in order_str.split(",") if f.strip()]
	for i, field_id in enumerate(order):
		mochi.db.execute(
			"update fields set rank=? where crm=? and class=? and id=?",
			i, crm_id, class_id, field_id
		)
	broadcast_event(crm_id, "field/reorder", {"crm": crm_id, "class": class_id, "order": order})
	return {"success": True}

# Option helpers
def do_option_create(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	if not class_id or not field_id:
		return {"error": "Type and field ID required", "code": 400}
	field_row = mochi.db.row("select fieldtype from fields where crm=? and class=? and id=?", crm_id, class_id, field_id)
	if not field_row:
		return {"error": "Field not found", "code": 404}
	if field_row["fieldtype"] != "enumerated":
		return {"error": "Options can only be added to enumerated fields", "code": 400}
	name = params.get("name")
	if not name or not name.strip():
		return {"error": "Name is required", "code": 400}
	option_id = name.strip().lower().replace(" ", "_")
	existing = mochi.db.exists("select 1 from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
	if existing:
		return {"error": "An option with this name already exists", "code": 400}
	max_rank = mochi.db.row("select max(rank) as m from options where crm=? and class=? and field=?", crm_id, class_id, field_id)
	rank = (max_rank["m"] or 0) + 1 if max_rank else 0
	colour = params.get("colour", "#94a3b8")
	icon = params.get("icon", "")
	mochi.db.execute(
		"insert into options (crm, class, field, id, name, colour, icon, rank) values (?, ?, ?, ?, ?, ?, ?, ?)",
		crm_id, class_id, field_id, option_id, name.strip(), colour, icon, rank
	)
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
		return {"error": "Type, field, and option ID required", "code": 400}
	option_row = mochi.db.row("select * from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
	if not option_row:
		return {"error": "Option not found", "code": 404}
	name = params.get("name")
	colour = params.get("colour")
	icon = params.get("icon")
	if name != None:
		mochi.db.execute("update options set name=? where crm=? and class=? and field=? and id=?", name.strip(), crm_id, class_id, field_id, option_id)
	if colour != None:
		mochi.db.execute("update options set colour=? where crm=? and class=? and field=? and id=?", colour, crm_id, class_id, field_id, option_id)
	if icon != None:
		mochi.db.execute("update options set icon=? where crm=? and class=? and field=? and id=?", icon, crm_id, class_id, field_id, option_id)
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
		return {"error": "Type, field, and option ID required", "code": 400}
	mochi.db.execute("delete from options where crm=? and class=? and field=? and id=?", crm_id, class_id, field_id, option_id)
	broadcast_event(crm_id, "option/delete", {"crm": crm_id, "class": class_id, "field": field_id, "id": option_id})
	return {"success": True}

def do_option_reorder(crm_id, crm, params):
	class_id = params.get("class")
	field_id = params.get("field")
	if not class_id or not field_id:
		return {"error": "Type and field ID required", "code": 400}
	order_str = params.get("order", "")
	order = [o.strip() for o in order_str.split(",") if o.strip()]
	for i, option_id in enumerate(order):
		mochi.db.execute(
			"update options set rank=? where crm=? and class=? and field=? and id=?",
			i, crm_id, class_id, field_id, option_id
		)
	broadcast_event(crm_id, "option/reorder", {"crm": crm_id, "class": class_id, "field": field_id, "order": order})
	return {"success": True}

# Hierarchy helper
def do_hierarchy_set(crm_id, crm, params):
	class_id = params.get("class")
	if not class_id:
		return {"error": "Type ID required", "code": 400}
	class_row = mochi.db.row("select id from classes where crm=? and id=?", crm_id, class_id)
	if not class_row:
		return {"error": "Type not found", "code": 404}
	parents_str = params.get("parents")
	if parents_str == None or parents_str == "_none_":
		parents = []
	elif parents_str == "":
		parents = [""]
	else:
		parents = [p.strip() for p in parents_str.split(",")]
	mochi.db.execute("delete from hierarchy where crm=? and class=?", crm_id, class_id)
	for parent in parents:
		if parent and parent != "":
			parent_exists = mochi.db.exists("select 1 from classes where crm=? and id=?", crm_id, parent)
			if not parent_exists:
				continue
		mochi.db.execute(
			"insert into hierarchy (crm, class, parent) values (?, ?, ?)",
			crm_id, class_id, parent
		)
	broadcast_event(crm_id, "hierarchy/set", {
		"crm": crm_id, "class": class_id, "parents": parents
	})
	return {"success": True}

# View helpers
def do_view_create(crm_id, crm, params):
	name = params.get("name")
	if not name or not name.strip():
		return {"error": "Name is required", "code": 400}
	viewtype = params.get("viewtype", "board")
	if viewtype not in ["board", "list"]:
		return {"error": "Invalid view type", "code": 400}
	view_id = name.strip().lower().replace(" ", "_")
	existing = mochi.db.exists("select 1 from views where crm=? and id=?", crm_id, view_id)
	if existing:
		return {"error": "A view with this name already exists", "code": 400}
	filter_str = params.get("filter", "")
	columns = params.get("columns", "")
	if viewtype == "board" and not columns:
		return {"error": "Columns field is required for board views", "code": 400}
	rows = params.get("rows", "")
	fields = params.get("fields", "title,priority,owner,due")
	sort = params.get("sort", "")
	direction = params.get("direction", "asc")
	border = params.get("border", "")
	next_rank = mochi.db.row("select coalesce(max(rank), -1) + 1 as r from views where crm=?", crm_id)
	rank = next_rank["r"] if next_rank else 0
	mochi.db.execute(
		"insert into views (crm, id, name, viewtype, filter, columns, rows, sort, direction, rank, border) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		crm_id, view_id, name.strip(), viewtype, filter_str, columns, rows, sort, direction, rank, border
	)
	for i, field in enumerate(fields.split(",")):
		if field.strip():
			mochi.db.execute(
				"insert into view_fields (crm, view, field, rank) values (?, ?, ?, ?)",
				crm_id, view_id, field.strip(), i
			)
	view_classes = params.get("classes", "")
	if view_classes:
		for cls_id in [c.strip() for c in view_classes.split(",") if c.strip()]:
			mochi.db.execute(
				"insert into view_classes (crm, view, class) values (?, ?, ?)",
				crm_id, view_id, cls_id
			)
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
		return {"error": "View ID required", "code": 400}
	view = mochi.db.row("select * from views where crm=? and id=?", crm_id, view_id)
	if not view:
		return {"error": "View not found", "code": 404}
	name = params.get("name")
	viewtype = params.get("viewtype")
	filter_str = params.get("filter")
	columns = params.get("columns")
	rows = params.get("rows")
	fields = params.get("fields")
	sort = params.get("sort")
	direction = params.get("direction")
	if name != None and name.strip() != "":
		mochi.db.execute("update views set name=? where crm=? and id=?", name.strip(), crm_id, view_id)
	if viewtype != None and viewtype != "":
		if viewtype not in ["board", "list"]:
			return {"error": "Invalid view type", "code": 400}
		mochi.db.execute("update views set viewtype=? where crm=? and id=?", viewtype, crm_id, view_id)
	if filter_str != None:
		mochi.db.execute("update views set filter=? where crm=? and id=?", filter_str, crm_id, view_id)
	if columns != None:
		mochi.db.execute("update views set columns=? where crm=? and id=?", columns, crm_id, view_id)
	if rows != None:
		mochi.db.execute("update views set rows=? where crm=? and id=?", rows, crm_id, view_id)
	if fields != None:
		mochi.db.execute("delete from view_fields where crm=? and view=?", crm_id, view_id)
		for i, field in enumerate(fields.split(",")):
			if field.strip():
				mochi.db.execute(
					"insert into view_fields (crm, view, field, rank) values (?, ?, ?, ?)",
					crm_id, view_id, field.strip(), i
				)
	if sort != None:
		mochi.db.execute("update views set sort=? where crm=? and id=?", sort, crm_id, view_id)
	if direction != None and direction != "":
		if direction not in ["asc", "desc"]:
			return {"error": "Invalid direction", "code": 400}
		mochi.db.execute("update views set direction=? where crm=? and id=?", direction, crm_id, view_id)
	border = params.get("border")
	if border != None:
		mochi.db.execute("update views set border=? where crm=? and id=?", border, crm_id, view_id)
	view_classes_input = params.get("classes")
	if view_classes_input != None:
		mochi.db.execute("delete from view_classes where crm=? and view=?", crm_id, view_id)
		if view_classes_input:
			cls_ids = [c.strip() for c in view_classes_input.split(",") if c.strip()]
			for cls_id in cls_ids:
				mochi.db.execute(
					"insert into view_classes (crm, view, class) values (?, ?, ?)",
					crm_id, view_id, cls_id
				)
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
		return {"error": "View ID required", "code": 400}
	count = mochi.db.row("select count(*) as cnt from views where crm=?", crm_id)
	if count and count["cnt"] <= 1:
		return {"error": "Cannot delete the last view", "code": 400}
	mochi.db.execute("delete from view_fields where crm=? and view=?", crm_id, view_id)
	mochi.db.execute("delete from view_classes where crm=? and view=?", crm_id, view_id)
	mochi.db.execute("delete from views where crm=? and id=?", crm_id, view_id)
	broadcast_event(crm_id, "view/delete", {"crm": crm_id, "id": view_id})
	return {"success": True}

def do_view_reorder(crm_id, crm, params):
	order_str = params.get("order", "")
	order = [v.strip() for v in order_str.split(",") if v.strip()]
	for i, view_id in enumerate(order):
		mochi.db.execute(
			"update views set rank=? where crm=? and id=?",
			i, crm_id, view_id
		)
	broadcast_event(crm_id, "view/reorder", {"crm": crm_id, "order": order})
	return {"success": True}
