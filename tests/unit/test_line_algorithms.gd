## Unit tests for LineAlgorithms.rasterize_path.
extends GdUnitTestSuite


func _rasterize(points: PackedVector2Array, algo: LineAlgorithms.LineAlgorithmType, perfect: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	LineAlgorithms.rasterize_path(points, 4, algo, perfect, out)
	return out


func _assert_8_connected_without_duplicates(cells: PackedVector2Array) -> void:
	for i in range(1, cells.size()):
		var d := (cells[i] - cells[i - 1]).abs()
		assert_bool(d.x <= 1.0 and d.y <= 1.0).override_failure_message(
			"gap between %s and %s" % [cells[i - 1], cells[i]]).is_true()
		assert_bool(cells[i] != cells[i - 1]).override_failure_message(
			"duplicate cell %s" % cells[i]).is_true()


func test_empty_path_clears_output() -> void:
	var out := PackedVector2Array([Vector2.ONE])
	LineAlgorithms.rasterize_path(PackedVector2Array(), 4, LineAlgorithms.LineAlgorithmType.BRESENHAM, true, out)
	assert_int(out.size()).is_equal(0)


func test_horizontal_line_cell_count() -> void:
	var cells := _rasterize(PackedVector2Array([Vector2(0, 0), Vector2(40, 0)]),
		LineAlgorithms.LineAlgorithmType.BRESENHAM, true)
	# 0..40 px at 4 px per cell is cells 0..10.
	assert_int(cells.size()).is_equal(11)
	assert_vector(cells[0]).is_equal(Vector2(0, 0))
	assert_vector(cells[10]).is_equal(Vector2(10, 0))


func test_polyline_is_continuous_for_both_algorithms() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(37, 13), Vector2(-20, 55), Vector2(80, 90), Vector2(81, 90)])
	for algo in [LineAlgorithms.LineAlgorithmType.BRESENHAM, LineAlgorithms.LineAlgorithmType.DDA]:
		for perfect in [false, true]:
			_assert_8_connected_without_duplicates(_rasterize(pts, algo, perfect))


func test_pixel_perfect_removes_l_corners() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(4, 0), Vector2(4, 4)])
	var raw := _rasterize(pts, LineAlgorithms.LineAlgorithmType.BRESENHAM, false)
	var clean := _rasterize(pts, LineAlgorithms.LineAlgorithmType.BRESENHAM, true)
	assert_int(raw.size()).is_equal(3)
	assert_int(clean.size()).is_equal(2)


func test_runaway_and_non_finite_points_do_not_hang() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(1e12, 1e12), Vector2(NAN, 0), Vector2(8, 8)])
	var start := Time.get_ticks_msec()
	var cells := _rasterize(pts, LineAlgorithms.LineAlgorithmType.BRESENHAM, true)
	assert_int(Time.get_ticks_msec() - start).is_less(500)
	assert_int(cells.size()).is_less(LineAlgorithms.MAX_SEGMENT_CELLS * 3)
