@tool
@icon("res://addons/lrd_pixel_rope_physics/icons/Curve2D.svg")
## Pixel-perfect rope simulation using Verlet integration.
##
## Verlet integration with position-based distance constraints. Each frame:
## 1. Detect collision contacts once (broad query, then one query per point)
## 2. Split the frame into many small substeps. In each substep:
##    a. Integrate positions (velocity = current_pos - old_pos)
##    b. Run one constraint pass, alternating sweep direction
##    c. Push points out of the cached contact planes
##
## Many substeps with one pass each gives a stiffer, less stretchy rope than
## a few substeps with many passes, at the same cost (Macklin et al. 2019,
## "Small Steps in Physics Simulation").
extends Node2D
class_name PixelRope

signal rope_broken
signal rope_grabbed(segment_index: int)
signal rope_released

enum RopeState { NORMAL, STRETCHED, BROKEN }
enum GrabMode { NONE, ANCHORS_ONLY, ANY_POINT }

# --- Rope Properties ---
@export_group("Rope Properties")
@export var segment_count: int = 100:
	set(v):
		segment_count = v
		if Engine.is_editor_hint(): queue_redraw()

@export var segment_length: float = 5.0:
	set(v):
		segment_length = v
		if Engine.is_editor_hint(): queue_redraw()

@export var rope_color: Color = Color(0.8, 0.6, 0.2):
	set(v):
		rope_color = v
		if Engine.is_editor_hint(): queue_redraw()

# --- Pixelation ---
@export_group("Pixelation Properties")
@export var pixel_size: int = 4:
	set(v):
		pixel_size = v
		if Engine.is_editor_hint(): queue_redraw()

@export var pixel_spacing: int = 0:
	set(v):
		pixel_spacing = v
		if Engine.is_editor_hint(): queue_redraw()

@export var line_algorithm: LineAlgorithms.LineAlgorithmType = LineAlgorithms.LineAlgorithmType.BRESENHAM:
	set(v):
		line_algorithm = v
		if Engine.is_editor_hint(): queue_redraw()

## Remove L-shaped corner pixels for a clean 1-pixel stroke.
@export var pixel_perfect: bool = true:
	set(v):
		pixel_perfect = v
		if Engine.is_editor_hint(): queue_redraw()

# --- Physics ---
@export_group("Physics Properties")
@export var gravity: Vector2 = Vector2(0, 980)
## Fraction of velocity kept every 1/60 s. Independent of frame rate and substeps.
@export_range(0.0, 1.0) var damping: float = 0.98
## Constraint passes per substep. Prefer raising physics_substeps instead.
@export_range(1, 50) var iterations: int = 1
## Substeps per physics frame. More substeps = stiffer, more stable rope.
@export_range(1, 64) var physics_substeps: int = 20
@export var max_stretch_factor: float = 2.0

# --- Anchors ---
@export_group("Anchor Properties")
@export var start_position: Vector2 = Vector2(-100, 0):
	set(v):
		start_position = v
		if _start_anchor: _start_anchor.position = v
		if Engine.is_editor_hint(): queue_redraw()

@export var end_position: Vector2 = Vector2(100, 0):
	set(v):
		end_position = v
		if _end_anchor: _end_anchor.position = v
		if Engine.is_editor_hint(): queue_redraw()

@export var anchor_radius: float = 8.0:
	set(v):
		anchor_radius = v
		_sync_anchor_properties()

@export var anchor_debug_color: Color = Color(0.0, 0.698, 0.885, 0.5):
	set(v):
		anchor_debug_color = v
		_sync_anchor_properties()

@export var show_anchor_debug: bool = true:
	set(v):
		show_anchor_debug = v
		_sync_anchor_properties()

# --- Dynamic Anchors ---
@export_group("Dynamic Anchors")
@export var dynamic_start_anchor: bool = false:
	set(v):
		dynamic_start_anchor = v
		if _points.size() > 0: _locked[0] = not v

@export var dynamic_end_anchor: bool = true:
	set(v):
		dynamic_end_anchor = v
		if _points.size() > segment_count: _locked[segment_count] = not v

@export_range(0.1, 10.0) var anchor_mass: float = 1.0
@export var anchor_jitter: float = 0.0
@export var anchor_gravity: Vector2 = Vector2.ZERO

# --- Collision ---
@export_group("Collision Properties")
@export var enable_collisions: bool = true
@export_flags_2d_physics var collision_mask: int = 1
@export_range(0.0, 1.0) var collision_bounce: float = 0.3
@export_range(0.0, 1.0) var collision_friction: float = 0.7
@export_range(1.0, 20.0) var collision_radius: float = 4.0
@export var show_collision_debug: bool = false:
	set(v):
		show_collision_debug = v
		queue_redraw()

# --- Interaction ---
@export_group("Interaction Properties")
@export var interaction_mode: GrabMode = GrabMode.ANY_POINT
@export_range(5.0, 50.0) var interaction_width: float = 20.0
@export_range(0.1, 1.0) var grab_strength: float = 0.8
@export var end_anchor_draggable: bool = true

# --- Internal State ---
# Struct-of-Arrays for better cache performance and simpler code.
# Instead of Array[Dictionary], we use parallel arrays.
var _points: PackedVector2Array = PackedVector2Array()
var _old_points: PackedVector2Array = PackedVector2Array()
var _locked: PackedByteArray = PackedByteArray()
var _masses: PackedFloat32Array = PackedFloat32Array()
## 1/mass, or 0 for points that must not move (locked or grabbed).
var _inv_masses: PackedFloat32Array = PackedFloat32Array()
var _sweep_forward: bool = true

var _start_anchor: Node2D
var _end_anchor: Node2D
var _state: RopeState = RopeState.NORMAL
var _initialized: bool = false

# Collision
var _space_state: PhysicsDirectSpaceState2D
var _collision_shape: CircleShape2D
var _collision_query: PhysicsShapeQueryParameters2D
var _broad_shape: RectangleShape2D
var _broad_query: PhysicsShapeQueryParameters2D
# Contact planes found once per frame and reused by every substep.
var _contact_points: PackedVector2Array = PackedVector2Array()
var _contact_normals: PackedVector2Array = PackedVector2Array()
var _has_contact: PackedByteArray = PackedByteArray()

# Rendering buffers, reused every frame to avoid allocations
var _cells: PackedVector2Array = PackedVector2Array()
var _tri_points: PackedVector2Array = PackedVector2Array()
var _line_buffer: PackedVector2Array = PackedVector2Array()

# Interaction
var _is_dragging: bool = false
var _grabbed_index: int = -1
var _grab_offset: Vector2 = Vector2.ZERO

# Editor
var _editor_mode: bool = false


func _ready() -> void:
	_editor_mode = Engine.is_editor_hint()
	_ensure_anchors()

	if _editor_mode:
		set_notify_transform(true)
		queue_redraw()
		return

	await get_tree().process_frame
	_init_rope()
	_initialized = true

	if enable_collisions:
		call_deferred("_init_collisions")


func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE and _start_anchor and _end_anchor:
		start_position = _start_anchor.position
		end_position = _end_anchor.position
	elif what == NOTIFICATION_TRANSFORM_CHANGED and _editor_mode:
		queue_redraw()


# ==========================================================================
# Rope Initialization
# ==========================================================================

func _init_rope() -> void:
	var count := segment_count + 1
	_points.resize(count)
	_old_points.resize(count)
	_locked.resize(count)
	_masses.resize(count)
	_inv_masses.resize(count)
	_contact_points.resize(count)
	_contact_normals.resize(count)
	_has_contact.resize(count)
	_has_contact.fill(0)

	var start_pos := _start_anchor.global_position
	var end_pos := _end_anchor.global_position
	var step := (end_pos - start_pos) / float(segment_count)

	for i in count:
		var pos := start_pos + step * float(i)
		_points[i] = pos
		_old_points[i] = pos
		_masses[i] = anchor_mass if (i == 0 or i == segment_count) else 1.0

		if i == 0:
			_locked[i] = 0 if dynamic_start_anchor else 1
		elif i == segment_count:
			_locked[i] = 0 if dynamic_end_anchor else 1
		else:
			_locked[i] = 0

	_state = RopeState.NORMAL


func _init_collisions() -> void:
	if _editor_mode or not enable_collisions:
		return

	_collision_shape = CircleShape2D.new()
	_collision_shape.radius = collision_radius

	_collision_query = PhysicsShapeQueryParameters2D.new()
	_collision_query.collision_mask = collision_mask
	# Wide margin so contacts the point reaches later this frame are found too.
	_collision_query.margin = collision_radius
	_collision_query.shape = _collision_shape

	_broad_shape = RectangleShape2D.new()
	_broad_query = PhysicsShapeQueryParameters2D.new()
	_broad_query.collision_mask = collision_mask
	_broad_query.shape = _broad_shape

	var world := get_world_2d()
	if world:
		_space_state = world.direct_space_state


# ==========================================================================
# Anchor Management
# ==========================================================================

func _ensure_anchors() -> void:
	_start_anchor = _get_or_create_anchor("StartAnchor", start_position)
	_end_anchor = _get_or_create_anchor("EndAnchor", end_position)


func _get_or_create_anchor(anchor_name: String, pos: Vector2) -> Node2D:
	var node := get_node_or_null(anchor_name)
	if node:
		node.position = pos
		if node is RopeAnchor and not node.position_changed.is_connected(_on_anchor_moved):
			node.position_changed.connect(_on_anchor_moved.bind(node))
		return node

	var anchor := RopeAnchor.new()
	anchor.name = anchor_name
	anchor.position = pos
	anchor.radius = anchor_radius
	anchor.debug_color = anchor_debug_color
	anchor.show_debug_shape = show_anchor_debug
	anchor.position_changed.connect(_on_anchor_moved.bind(anchor))
	add_child(anchor)

	if _editor_mode and get_tree().edited_scene_root:
		anchor.owner = get_tree().edited_scene_root

	return anchor


func _sync_anchor_properties() -> void:
	for anchor in [_start_anchor, _end_anchor]:
		if anchor and anchor is RopeAnchor:
			anchor.radius = anchor_radius
			anchor.debug_color = anchor_debug_color
			anchor.show_debug_shape = show_anchor_debug


func _on_anchor_moved(anchor: RopeAnchor) -> void:
	if anchor.name == "StartAnchor":
		start_position = anchor.position
	elif anchor.name == "EndAnchor":
		end_position = anchor.position
	queue_redraw()


# ==========================================================================
# Physics - Verlet Integration
# ==========================================================================

func _physics_process(delta: float) -> void:
	if _editor_mode:
		_editor_check_anchors()
		return

	if not _initialized or _points.is_empty():
		return

	_handle_dragging()

	if _state == RopeState.BROKEN:
		queue_redraw()
		return

	var sub_delta := delta / float(physics_substeps)
	# Per-substep factors derived from per-1/60s settings, so tuning doesn't
	# change when the substep count or frame rate changes.
	var velocity_keep := pow(damping, sub_delta * 60.0)
	var friction_keep := pow(1.0 - collision_friction, sub_delta * 60.0)

	_update_inv_masses()

	# Pin non-dynamic anchors to their node positions
	if not dynamic_start_anchor:
		_points[0] = _start_anchor.global_position
	if not dynamic_end_anchor:
		_points[segment_count] = _end_anchor.global_position

	var colliding := enable_collisions and _detect_collisions()

	for substep in physics_substeps:
		_verlet_integrate(sub_delta, velocity_keep, substep == 0)
		_solve_constraints()

		if colliding:
			_resolve_collisions(friction_keep)

	# Sync dynamic anchor nodes to simulation
	if dynamic_start_anchor:
		_start_anchor.global_position = _points[0]
	if dynamic_end_anchor:
		_end_anchor.global_position = _points[segment_count]

	_check_rope_state()
	queue_redraw()


## Locked and grabbed points get inverse mass 0, so the solver never moves them.
func _update_inv_masses() -> void:
	for i in _points.size():
		if _locked[i] or _grabbed_index == i:
			_inv_masses[i] = 0.0
		else:
			_inv_masses[i] = 1.0 / _masses[i]


## Verlet integration step: position += velocity * keep + gravity * dt^2
## Velocity is implicitly stored as (position - old_position).
## Gravity is an acceleration, so it does not depend on mass.
func _verlet_integrate(delta: float, velocity_keep: float, apply_jitter: bool) -> void:
	var dt2 := delta * delta
	var g_step := gravity * dt2
	var anchor_g_step := (anchor_gravity if anchor_gravity != Vector2.ZERO else gravity) * dt2

	for i in _points.size():
		if _inv_masses[i] == 0.0:
			continue

		var pos := _points[i]
		var velocity := pos - _old_points[i]
		var is_end := i == 0 or i == segment_count

		# Jitter once per frame (not per substep) so its strength
		# doesn't depend on the substep count.
		if apply_jitter and is_end and anchor_jitter > 0.0:
			velocity += Vector2(
				randf_range(-anchor_jitter, anchor_jitter),
				randf_range(-anchor_jitter, anchor_jitter)
			)

		_old_points[i] = pos
		_points[i] = pos + velocity * velocity_keep + (anchor_g_step if is_end else g_step)


## One or more passes over the distance constraints between adjacent points.
## Sweep direction alternates every pass so the rope isn't biased toward
## one end. Corrections are split by inverse mass, so a point next to a fixed
## anchor takes the whole correction and converges in one pass.
func _solve_constraints() -> void:
	var rest := segment_length
	for _iter in iterations:
		var i := 0 if _sweep_forward else segment_count - 1
		var step := 1 if _sweep_forward else -1
		_sweep_forward = not _sweep_forward

		for _k in segment_count:
			var w1 := _inv_masses[i]
			var w2 := _inv_masses[i + 1]
			var w := w1 + w2
			if w > 0.0:
				var p1 := _points[i]
				var p2 := _points[i + 1]
				var diff := p2 - p1
				var dist := diff.length()
				if dist > 0.0001:
					var corr := diff * ((dist - rest) / (dist * w))
					_points[i] = p1 + corr * w1
					_points[i + 1] = p2 - corr * w2
			i += step


# ==========================================================================
# Collision Detection
# ==========================================================================

## Finds contact planes once per frame. A single broad query over the rope's
## bounding box skips all per-point queries while the rope is in open air.
## Returns true if any point has a contact to resolve this frame.
func _detect_collisions() -> bool:
	if not _space_state:
		var world := get_world_2d()
		if not world:
			return false
		_space_state = world.direct_space_state

	if not _collision_query or not _broad_query:
		return false

	_has_contact.fill(0)

	# Broad phase: one box covering the whole rope plus how far it can move.
	var bounds := Rect2(_points[0], Vector2.ZERO)
	var max_speed := 0.0
	for i in _points.size():
		bounds = bounds.expand(_points[i])
		max_speed = maxf(max_speed, (_points[i] - _old_points[i]).length_squared())
	var pad := collision_radius * 2.0 + sqrt(max_speed) * 2.0
	bounds = bounds.grow(pad)
	_broad_shape.size = bounds.size
	_broad_query.transform = Transform2D(0.0, bounds.get_center())
	if _space_state.intersect_shape(_broad_query, 1).is_empty():
		return false

	# Narrow phase: one rest-info query per movable point.
	var found := false
	for i in _points.size():
		if _inv_masses[i] == 0.0:
			continue
		_collision_query.transform = Transform2D(0.0, _points[i])
		var info := _space_state.get_rest_info(_collision_query)
		if info.is_empty():
			continue
		_contact_points[i] = info["point"]
		_contact_normals[i] = info["normal"]
		_has_contact[i] = 1
		found = true
	return found


## Pushes points out of their cached contact planes. Runs every substep.
func _resolve_collisions(friction_keep: float) -> void:
	for i in _points.size():
		if not _has_contact[i] or _inv_masses[i] == 0.0:
			continue

		var n := _contact_normals[i]
		var p := _points[i]
		var depth := collision_radius - (p - _contact_points[i]).dot(n)
		if depth <= 0.0:
			continue

		# Split velocity into normal and tangent parts before the push-out,
		# so the correction itself doesn't turn into extra bounce.
		var vel := p - _old_points[i]
		var vn := vel.dot(n)
		var vt := vel - n * vn
		if vn < 0.0:
			vn = -vn * collision_bounce

		p += n * depth
		_points[i] = p
		_old_points[i] = p - (vt * friction_keep + n * vn)


# ==========================================================================
# Interaction - Simple distance-based (no per-segment Area2D)
# ==========================================================================

func _handle_dragging() -> void:
	if not _is_dragging:
		return

	var mouse_pos := get_global_mouse_position()

	if _grabbed_index >= 0 and _grabbed_index < _points.size():
		var target := mouse_pos + _grab_offset
		_points[_grabbed_index] = _points[_grabbed_index].lerp(target, grab_strength)
		_old_points[_grabbed_index] = _points[_grabbed_index]
	elif end_anchor_draggable and not dynamic_end_anchor:
		_end_anchor.global_position = mouse_pos
		_points[segment_count] = mouse_pos


func _input(event: InputEvent) -> void:
	if _editor_mode or not _initialized:
		return

	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return

	if event.pressed:
		_try_grab(get_global_mouse_position())
	else:
		_release_grab()


func _try_grab(mouse_pos: Vector2) -> void:
	if interaction_mode == GrabMode.NONE:
		return

	var best_index := -1
	var best_dist := interaction_width

	# Check end anchor first
	if end_anchor_draggable and not dynamic_end_anchor:
		var d := mouse_pos.distance_to(_points[segment_count])
		if d < best_dist:
			best_dist = d
			best_index = -2  # sentinel for end anchor drag

	# Check all segments if allowed
	if interaction_mode == GrabMode.ANY_POINT:
		for i in _points.size():
			if _locked[i]:
				continue
			var d := mouse_pos.distance_to(_points[i])
			if d < best_dist:
				best_dist = d
				best_index = i

	if best_index == -2:
		_is_dragging = true
		_grabbed_index = -1
	elif best_index >= 0:
		_is_dragging = true
		_grabbed_index = best_index
		_grab_offset = _points[best_index] - mouse_pos
		rope_grabbed.emit(best_index)


func _release_grab() -> void:
	if _grabbed_index >= 0:
		rope_released.emit()
	_is_dragging = false
	_grabbed_index = -1

	if _state == RopeState.BROKEN:
		reset_rope()


# ==========================================================================
# Rope State
# ==========================================================================

func _check_rope_state() -> void:
	var total_length := 0.0
	for i in segment_count:
		total_length += _points[i].distance_to(_points[i + 1])

	var ideal := segment_length * segment_count
	var stretch := total_length / ideal

	if stretch >= max_stretch_factor:
		_state = RopeState.BROKEN
		rope_broken.emit()
	elif stretch >= max_stretch_factor * 0.8:
		_state = RopeState.STRETCHED
	else:
		_state = RopeState.NORMAL


func break_rope() -> void:
	_state = RopeState.BROKEN
	rope_broken.emit()


func reset_rope() -> void:
	_state = RopeState.NORMAL
	_init_rope()


func get_state() -> int:
	return _state


# ==========================================================================
# Rendering - Pixelated Line Drawing
# ==========================================================================

func _draw() -> void:
	if _editor_mode:
		_draw_editor_preview()
		return

	if _points.is_empty():
		return

	if _state == RopeState.BROKEN:
		_draw_straight(_start_anchor.global_position, _end_anchor.global_position, Color.RED)
	else:
		var color := Color.DARK_ORANGE if _state == RopeState.STRETCHED else rope_color
		_draw_pixel_path(_points, color)

	if enable_collisions and show_collision_debug:
		_draw_collision_debug()


func _draw_editor_preview() -> void:
	if _start_anchor and _end_anchor:
		_draw_straight(_start_anchor.global_position, _end_anchor.global_position, rope_color)
	else:
		_draw_straight(to_global(start_position), to_global(end_position), rope_color)


func _draw_straight(from_global: Vector2, to_global_pos: Vector2, color: Color) -> void:
	_line_buffer.resize(2)
	_line_buffer[0] = from_global
	_line_buffer[1] = to_global_pos
	_draw_pixel_path(_line_buffer, color)


## Rasterizes the whole rope as one pixel path on a world-aligned grid
## (so pixels don't shimmer when the node moves) and submits every pixel
## in a single draw call.
func _draw_pixel_path(global_points: PackedVector2Array, color: Color) -> void:
	var ps := maxi(pixel_size, 1)
	LineAlgorithms.rasterize_path(global_points, ps, line_algorithm, pixel_perfect, _cells)
	if _cells.is_empty():
		return

	var step := pixel_spacing + 1
	var count := ceili(float(_cells.size()) / float(step))
	_tri_points.resize(count * 6)

	var size := float(ps)
	var right := Vector2(size, 0.0)
	var down := Vector2(0.0, size)
	var k := 0
	var j := 0
	while j < _cells.size():
		var a := _cells[j] * size
		var b := a + right
		var c := b + down
		var d := a + down
		_tri_points[k] = a
		_tri_points[k + 1] = b
		_tri_points[k + 2] = c
		_tri_points[k + 3] = a
		_tri_points[k + 4] = c
		_tri_points[k + 5] = d
		k += 6
		j += step

	# Cells are in global space; undo this node's transform while drawing them.
	draw_set_transform_matrix(get_global_transform().affine_inverse())
	RenderingServer.canvas_item_add_triangle_array(
		get_canvas_item(), PackedInt32Array(), _tri_points, PackedColorArray([color]))
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_collision_debug() -> void:
	var debug_color := Color(1.0, 0.3, 0.3, 0.4)
	for i in _points.size():
		var pos := to_local(_points[i])
		draw_circle(pos, collision_radius, debug_color)

		if _has_contact.size() > i and _has_contact[i]:
			var contact := to_local(_contact_points[i])
			draw_circle(contact, 2.0, Color.RED)
			draw_line(contact, contact + _contact_normals[i] * 10.0, Color.GREEN, 1.0)


# ==========================================================================
# Editor Helpers
# ==========================================================================

func _editor_check_anchors() -> void:
	if _start_anchor and _end_anchor:
		var sp := _start_anchor.position
		var ep := _end_anchor.position
		if sp != start_position or ep != end_position:
			start_position = sp
			end_position = ep
			queue_redraw()
