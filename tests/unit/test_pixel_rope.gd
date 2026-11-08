## Unit tests for PixelRope's simulation core. The rope's own physics tick is
## disabled and _physics_process is driven by hand, so every test controls delta.
extends GdUnitTestSuite

const GRAVITY := 980.0


func _make_rope(segments: int = 10, seg_len: float = 10.0) -> PixelRope:
	var rope := PixelRope.new()
	rope.segment_count = segments
	rope.segment_length = seg_len
	rope.enable_collisions = false
	rope.start_position = Vector2(0, 0)
	rope.end_position = Vector2(segments * seg_len, 0)
	add_child(auto_free(rope))
	rope.set_physics_process(false)
	rope._init_rope()
	rope._initialized = true
	return rope


## A rope with both ends free and no damping is a rigid body in free fall:
## every point should follow y = g*t^2/2 no matter how the time step changes.
func _make_falling_rope() -> PixelRope:
	var rope := _make_rope(4, 10.0)
	rope.damping = 1.0
	rope.gravity = Vector2(0, GRAVITY)
	rope.dynamic_start_anchor = true
	rope.dynamic_end_anchor = true
	rope._locked.fill(0)
	return rope


func _step(rope: PixelRope, delta: float, frames: int) -> void:
	for _i in frames:
		rope._physics_process(delta)


func test_free_fall_matches_analytic_at_fixed_rate() -> void:
	var rope := _make_falling_rope()
	_step(rope, 1.0 / 60.0, 60)
	# 0.5 * 980 * 1^2 = 490 px. Verlet is exact for constant acceleration up to
	# the start-up offset of half a step.
	assert_float(rope._points[2].y).is_equal_approx(490.0, 10.0)


func test_free_fall_survives_time_step_change() -> void:
	# Half a second at 60 Hz, then half a second at 120 Hz (e.g. a physics tick
	# change or Engine.time_scale = 0.5). Uncorrected Verlet keeps the old
	# per-step displacement, so the rope would suddenly move twice as fast.
	var rope := _make_falling_rope()
	_step(rope, 1.0 / 60.0, 30)
	_step(rope, 1.0 / 120.0, 60)
	assert_float(rope._points[2].y).is_equal_approx(490.0, 10.0)


func test_free_fall_survives_substep_change() -> void:
	var rope := _make_falling_rope()
	_step(rope, 1.0 / 60.0, 30)
	rope.physics_substeps = 5
	_step(rope, 1.0 / 60.0, 30)
	assert_float(rope._points[2].y).is_equal_approx(490.0, 10.0)


func test_changing_segment_count_at_runtime_rebuilds_rope() -> void:
	var rope := _make_rope(10, 10.0)
	rope.segment_count = 20
	assert_int(rope._points.size()).is_equal(21)
	assert_int(rope._old_points.size()).is_equal(21)
	assert_int(rope._locked.size()).is_equal(21)
	_step(rope, 1.0 / 60.0, 5)
	assert_int(rope.get_state()).is_not_equal(PixelRope.RopeState.BROKEN)
	rope.segment_count = 3
	assert_int(rope._points.size()).is_equal(4)
	_step(rope, 1.0 / 60.0, 5)


func test_invalid_parameters_are_clamped() -> void:
	var rope := _make_rope(10, 10.0)
	rope.segment_count = 0
	rope.segment_length = -5.0
	rope.physics_substeps = 0
	assert_int(rope.segment_count).is_greater_equal(1)
	assert_float(rope.segment_length).is_greater(0.0)
	assert_int(rope.physics_substeps).is_greater_equal(1)
	_step(rope, 1.0 / 60.0, 10)
	for p in rope._points:
		assert_bool(p.is_finite()).is_true()


func test_hanging_rope_settles_without_breaking() -> void:
	# Pinned at the start, free at the end: should swing down and stay intact.
	var rope := _make_rope(20, 5.0)
	_step(rope, 1.0 / 60.0, 240)
	assert_int(rope.get_state()).is_not_equal(PixelRope.RopeState.BROKEN)
	var end := rope._points[rope.segment_count]
	var start := rope._points[0]
	# Hangs roughly straight down from the pinned start, about 100 px long.
	assert_float(end.y - start.y).is_greater(80.0)
	assert_float(absf(end.x - start.x)).is_less(30.0)


func test_non_finite_points_reset_the_rope() -> void:
	var rope := _make_rope(10, 10.0)
	rope._points[5] = Vector2(NAN, NAN)
	rope._old_points[5] = Vector2(NAN, NAN)
	_step(rope, 1.0 / 60.0, 2)
	for p in rope._points:
		assert_bool(p.is_finite()).is_true()


func test_overstretch_breaks_and_emits_signal() -> void:
	var rope := _make_rope(10, 10.0)
	rope.max_stretch_factor = 1.5
	var monitor := monitor_signals(rope, false)
	# Yank the free end far away and hold it there.
	for _i in 3:
		rope._points[rope.segment_count] = Vector2(1000, 0)
		rope._old_points[rope.segment_count] = Vector2(1000, 0)
		rope._locked[rope.segment_count] = 1
		rope._physics_process(1.0 / 60.0)
	assert_int(rope.get_state()).is_equal(PixelRope.RopeState.BROKEN)
	await assert_signal(monitor).is_emitted("rope_broken")


func test_toggling_dynamic_anchors_at_runtime_updates_locks() -> void:
	var rope := _make_rope(10, 10.0)
	rope.dynamic_start_anchor = true
	rope.dynamic_end_anchor = false
	assert_int(rope._locked[0]).is_equal(0)
	assert_int(rope._locked[rope.segment_count]).is_equal(1)
	rope.dynamic_start_anchor = false
	rope.dynamic_end_anchor = true
	assert_int(rope._locked[0]).is_equal(1)
	assert_int(rope._locked[rope.segment_count]).is_equal(0)


func test_zero_delta_freezes_the_rope() -> void:
	var rope := _make_falling_rope()
	_step(rope, 1.0 / 60.0, 10)
	var before := rope._points.duplicate()
	_step(rope, 0.0, 10)
	assert_vector(rope._points[2]).is_equal(before[2])
	# And it carries on at the right speed once time resumes.
	_step(rope, 1.0 / 60.0, 50)
	assert_float(rope._points[2].y).is_equal_approx(490.0, 10.0)


func _click(rope: PixelRope, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	rope._unhandled_input(ev)


func test_grab_returns_whether_it_grabbed() -> void:
	var rope := _make_rope(10, 10.0)
	assert_bool(rope._try_grab(rope._points[5])).is_true()
	assert_int(rope._grabbed_index).is_equal(5)
	rope._release_grab()
	assert_bool(rope._try_grab(rope._points[5] + Vector2(0, 500))).is_false()
	assert_bool(rope._is_dragging).is_false()


func test_release_elsewhere_does_not_reset_a_broken_rope() -> void:
	# A mouse-up anywhere used to reset every broken rope in the scene.
	var rope := _make_rope(10, 10.0)
	rope.break_rope()
	_click(rope, false)
	assert_int(rope.get_state()).is_equal(PixelRope.RopeState.BROKEN)
