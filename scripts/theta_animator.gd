extends AnimationTree
## Builds and drives THETA's animation graph.
##
##   loco (BlendSpace1D: Idle 0 -> Walk -> Run 1)  --TimeScale--\
##   THETA_JumpTuck  ----------------------------------------------> state (Transition: ground / tuck / dive / fall / crouch)
##   THETA_Dive, THETA_Fall, THETA_Crouch  -----------------------/
##        state --> aim (Blend2, right arm only, THETA_Aim) --> recoil (OneShot, right arm only) --> output
##
## The aim/recoil layers are filtered to the right arm, so shooting works on the ground,
## mid-somersault and while diving.

@export var model_path: NodePath = ^"../PivotPoint/Model/theta"
## Stick magnitude at which the walk is fully in / the run takes over.
@export var walk_point := 0.2
@export var walk_end_point := 0.55
@export var run_point := 0.85
## Playback speed of the walk/run cycle at full stick (1 = mocap speed).
@export var max_cycle_speed := 1.5
@export var state_xfade := 0.15
@export var aim_blend_in := 18.0   # per second
@export var aim_blend_out := 6.0
@export var aim_hold_time := 0.6   # seconds the arm stays up after the last shot

const RIGHT_ARM_KEYS := ["shoulder.R", "upper_arm.R", "forearm.R", "hand.R", "palm", "f_index", "f_middle", "f_ring", "f_pinky", "thumb"]

var _aim := 0.0
var _aim_timer := 0.0
var _loco := 0.0
var _skeleton: Skeleton3D
var _state := "ground"


func _ready() -> void:
	var model := get_node(model_path)
	var player: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	_skeleton = model.find_child("Skeleton3D", true, false)
	anim_player = get_path_to(player)
	tree_root = _build_graph(player)
	active = true


func _build_graph(player: AnimationPlayer) -> AnimationNodeBlendTree:
	var bt := AnimationNodeBlendTree.new()

	var loco := AnimationNodeBlendSpace1D.new()
	loco.min_space = 0.0
	loco.max_space = 1.0
	loco.add_blend_point(_anim("THETA_Idle"), 0.0)
	loco.add_blend_point(_anim("THETA_Walk"), walk_point)
	loco.add_blend_point(_anim("THETA_Walk"), walk_end_point)
	loco.add_blend_point(_anim("THETA_Run"), run_point)
	bt.add_node("loco", loco, Vector2(0, 0))

	var speed := AnimationNodeTimeScale.new()
	bt.add_node("speed", speed, Vector2(200, 0))
	bt.connect_node("speed", 0, "loco")

	var state := AnimationNodeTransition.new()
	state.xfade_time = state_xfade
	for input in ["ground", "tuck", "dive", "fall", "crouch", "roll"]:
		state.add_input(input)
	bt.add_node("state", state, Vector2(400, 0))
	bt.connect_node("state", 0, "speed")
	bt.add_node("tuck", _anim("THETA_JumpTuck"), Vector2(200, 150))
	bt.connect_node("state", 1, "tuck")
	bt.add_node("dive", _anim("THETA_Dive"), Vector2(200, 250))
	bt.connect_node("state", 2, "dive")
	bt.add_node("fall", _anim("THETA_Fall"), Vector2(200, 350))
	bt.connect_node("state", 3, "fall")
	bt.add_node("crouch", _anim("THETA_Crouch"), Vector2(200, 450))
	bt.connect_node("state", 4, "crouch")
	bt.add_node("roll", _anim("THETA_Roll"), Vector2(200, 550))
	bt.connect_node("state", 5, "roll")

	var aim := AnimationNodeBlend2.new()
	aim.filter_enabled = true
	bt.add_node("aim", aim, Vector2(600, 0))
	bt.add_node("aim_pose", _anim("THETA_Aim"), Vector2(400, 200))
	bt.connect_node("aim", 0, "state")
	bt.connect_node("aim", 1, "aim_pose")

	var recoil := AnimationNodeOneShot.new()
	recoil.filter_enabled = true
	recoil.fadein_time = 0.02
	recoil.fadeout_time = 0.1
	bt.add_node("recoil", recoil, Vector2(800, 0))
	bt.add_node("recoil_anim", _anim("THETA_Recoil"), Vector2(600, 200))
	bt.connect_node("recoil", 0, "aim")
	bt.connect_node("recoil", 1, "recoil_anim")
	bt.connect_node("output", 0, "recoil")

	# Right-arm filter, built from the actual track paths so it survives re-exports.
	var walk := player.get_animation("THETA_Walk")
	for i in walk.get_track_count():
		var path := walk.track_get_path(i)
		var bone := String(path.get_concatenated_subnames())
		if bone.ends_with(".R") and RIGHT_ARM_KEYS.any(func(k): return bone.contains(k)):
			aim.set_filter_path(path, true)
			recoil.set_filter_path(path, true)
	return bt


func _anim(name: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = name
	return a


## 0 = standing, 1 = full stick.
func set_locomotion(stick: float, delta: float) -> void:
	_loco = lerpf(_loco, clampf(stick, 0.0, 1.0), 1.0 - exp(-12.0 * delta))
	set("parameters/loco/blend_position", _loco)
	set("parameters/speed/scale", lerpf(1.0, max_cycle_speed, _loco))


## "ground", "tuck", "dive", "fall", "crouch" or "roll".
func set_state(state: String) -> void:
	if state == _state:
		return
	_state = state
	set("parameters/state/transition_request", state)


## Call when a bullet is fired.
func shoot() -> void:
	_aim_timer = aim_hold_time
	_aim = 1.0  # snap the arm up so the first shot already comes from the raised hand
	set("parameters/aim/blend_amount", _aim)
	set("parameters/recoil/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func is_aiming() -> bool:
	return _aim > 0.5


func _process(delta: float) -> void:
	_aim_timer = maxf(_aim_timer - delta, 0.0)
	var target := 1.0 if _aim_timer > 0.0 else 0.0
	var rate := aim_blend_in if target > _aim else aim_blend_out
	_aim = move_toward(_aim, target, rate * delta)
	set("parameters/aim/blend_amount", _aim)


## World position of the right index fingertip (the "barrel"), or null if the skeleton is missing.
func get_muzzle_position() -> Variant:
	if _skeleton == null:
		return null
	var idx := _skeleton.find_bone("DEF-f_index.03.R")
	if idx < 0:
		return null
	var pose := _skeleton.get_bone_global_pose(idx)
	var tip := pose.origin + pose.basis.y.normalized() * 0.03
	return _skeleton.global_transform * tip


## Lowest world height of any bone (the skeleton's current pose). Used to keep rolls on the floor.
func get_lowest_bone_height() -> float:
	if _skeleton == null:
		return 0.0
	var xf := _skeleton.global_transform
	var lowest := INF
	for i in _skeleton.get_bone_count():
		if _skeleton.get_bone_name(i) == "root":
			continue  # sits at the feet of the rest pose, not on the body
		lowest = minf(lowest, (xf * _skeleton.get_bone_global_pose(i).origin).y)
	return lowest
