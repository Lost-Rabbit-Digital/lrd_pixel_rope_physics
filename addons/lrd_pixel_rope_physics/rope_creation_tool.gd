@tool
extends RefCounted
## The 2D editor toolbar button for making ropes: toggle it on, then click and drag in the 2D
## view to add a [code]PixelRope[/code] from the press point to the release point. Each rope is
## one undo step. Owned by [code]plugin.gd[/code].

const ICON := preload("res://addons/lrd_pixel_rope_physics/icons/Curve2D.svg")
const OFF_TOOLTIP := "Rope tool (off): click to drag out new PixelRope nodes in the 2D view"
const ON_TOOLTIP := "Rope tool (on): click and drag in the 2D view to add a PixelRope"
## Ropes get one segment per this many pixels of length...
const PIXELS_PER_SEGMENT := 20.0
## ...but never fewer than this many segments.
const MIN_SEGMENTS := 5

var _plugin: EditorPlugin
var _button: Button
var _rope: PixelRope
var _start: Vector2


func initialize(plugin: EditorPlugin) -> void:
	_plugin = plugin

	_button = Button.new()
	_button.toggle_mode = true
	_button.flat = true
	_button.icon = ICON
	_button.tooltip_text = OFF_TOOLTIP
	_button.toggled.connect(_on_toggled)
	_plugin.add_control_to_container(EditorPlugin.CONTAINER_CANVAS_EDITOR_MENU, _button)


func cleanup() -> void:
	_cancel()
	if _button:
		_plugin.remove_control_from_container(EditorPlugin.CONTAINER_CANVAS_EDITOR_MENU, _button)
		_button.queue_free()
		_button = null


## Returns true when the event was used to place a rope, so the 2D editor ignores it.
func handle_input(event: InputEvent) -> bool:
	if not _button or not _button.button_pressed:
		return false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			return _begin(_to_world(event.position))
		if _rope:
			_finish(_to_world(event.position))
			return true
		return false

	if event is InputEventMouseMotion and _rope:
		_rope.end_position = _rope.to_local(_to_world(event.position))
		return true

	return false


func _on_toggled(on: bool) -> void:
	_button.tooltip_text = ON_TOOLTIP if on else OFF_TOOLTIP
	if not on:
		_cancel()


## Adds a temporary rope at [param world_pos] that follows the mouse until release.
func _begin(world_pos: Vector2) -> bool:
	var scene_root := EditorInterface.get_edited_scene_root()
	if not scene_root is Node2D and not scene_root is Control:
		return false

	_start = world_pos
	_rope = PixelRope.new()
	_rope.name = "PixelRope"
	scene_root.add_child(_rope)
	_rope.global_position = world_pos
	_rope.start_position = Vector2.ZERO
	_rope.end_position = Vector2.ZERO
	return true


## Sizes the rope to the drag, then removes the temporary node and re-adds it through undo/redo.
func _finish(world_pos: Vector2) -> void:
	var rope := _rope
	_rope = null
	var scene_root := rope.get_parent()
	scene_root.remove_child(rope)

	var length := _start.distance_to(world_pos)
	rope.start_position = Vector2.ZERO
	rope.end_position = world_pos - _start
	rope.segment_count = maxi(int(length / PIXELS_PER_SEGMENT), MIN_SEGMENTS)
	rope.segment_length = maxf(length, 1.0) / float(rope.segment_count)

	var undo_redo := _plugin.get_undo_redo()
	undo_redo.create_action("Create PixelRope")
	undo_redo.add_do_method(scene_root, "add_child", rope, true)
	undo_redo.add_do_method(self, "_set_owner_recursive", rope, scene_root)
	undo_redo.add_do_method(EditorInterface.get_selection(), "clear")
	undo_redo.add_do_method(EditorInterface.get_selection(), "add_node", rope)
	undo_redo.add_do_reference(rope)
	undo_redo.add_undo_method(scene_root, "remove_child", rope)
	undo_redo.commit_action()

	_button.button_pressed = false


func _cancel() -> void:
	if _rope:
		_rope.queue_free()
		_rope = null


## Gives the rope and the anchors it made for itself an owner so they save with the scene.
func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		_set_owner_recursive(child, owner)


func _to_world(screen_pos: Vector2) -> Vector2:
	var viewport := EditorInterface.get_editor_viewport_2d()
	return viewport.global_canvas_transform.affine_inverse() * screen_pos
