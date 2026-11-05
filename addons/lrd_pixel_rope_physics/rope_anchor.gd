@tool
@icon("res://addons/lrd_pixel_rope_physics/icons/CircleShape2D.svg")
class_name RopeAnchor
extends Node2D
## One end of a [code]PixelRope[/code], made by the rope as [code]StartAnchor[/code] and
## [code]EndAnchor[/code]. Carries an [Area2D] so other nodes can detect the rope's ends. Move it
## with the editor's move tool; the parent rope follows.

## Emitted in the editor when the anchor is moved.
signal position_changed

@export var radius: float = 8.0:
	set(v):
		radius = v
		_update_shape()

@export var debug_color: Color = Color(0.7, 0.7, 1.0, 0.5):
	set(v):
		debug_color = v
		_update_debug()

@export var show_debug_shape: bool = true:
	set(v):
		show_debug_shape = v
		_update_debug()

var _is_editor: bool = false
var _last_position: Vector2


func _ready() -> void:
	_is_editor = Engine.is_editor_hint()
	_last_position = position
	_ensure_collision_area()
	if _is_editor:
		set_notify_transform(true)


func _ensure_collision_area() -> void:
	if has_node("Area2D"):
		_update_shape()
		_update_debug()
		return

	var area := Area2D.new()
	area.name = "Area2D"

	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"

	var shape := CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	collision.debug_color = debug_color if show_debug_shape else Color(0, 0, 0, 0)

	area.add_child(collision)
	add_child(area)

	if _is_editor and get_tree().edited_scene_root:
		area.owner = get_tree().edited_scene_root
		collision.owner = get_tree().edited_scene_root


func _update_shape() -> void:
	var collision := _get_collision()
	if collision and collision.shape is CircleShape2D:
		collision.shape.radius = radius


func _update_debug() -> void:
	var collision := _get_collision()
	if collision:
		collision.debug_color = debug_color if show_debug_shape else Color(0, 0, 0, 0)


func _get_collision() -> CollisionShape2D:
	var area := get_node_or_null("Area2D")
	if area:
		return area.get_node_or_null("CollisionShape2D")
	return null


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and _is_editor and position != _last_position:
		_last_position = position
		_notify_parent()


func _notify_parent() -> void:
	if not _is_editor:
		return

	var parent := get_parent()
	if parent is PixelRope:
		if name == "StartAnchor":
			parent.start_position = position
		elif name == "EndAnchor":
			parent.end_position = position
		parent.queue_redraw()

	position_changed.emit()
