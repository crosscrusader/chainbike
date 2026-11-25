"""Author THETA's game animations on THETA_Skeleton.

blender -b art/theta2/THETA2_game.blend --python art/theta2/tools/make_anims.py

  THETA_Walk / THETA_Run  retargeted from the mocap in "running animation/WALK-RUN-CYCLES-MOCAP"
                          (02-walkforward.fbx, 05-running-treadmill.fbx), one clean loop each, in place.
  THETA_Idle              hand-keyed breathing loop
  THETA_JumpTuck          take-off into a tucked somersault ball (non-looping, holds last frame)
  THETA_Dive              stretched head-first dive the spin settles into
  THETA_Fall              loose falling pose (walked off a ledge)
  THETA_Aim               right arm extended, gun forward (single pose, blended on the arm only)
  THETA_Recoil            short kick of the gun arm per shot

Everything is keyed at 30 fps. Re-run export_glb.py afterwards.
"""
import bpy, os, sys, math
from mathutils import Vector, Quaternion, Matrix

sys.path.insert(0, os.path.dirname(__file__))
from posing import set_rot, reset, set_loc, arm_quat

FPS = 30
here = os.path.dirname(bpy.data.filepath)
MOCAP = os.path.normpath(os.path.join(here, "..", "..", "running animation", "WALK-RUN-CYCLES-MOCAP"))

sc = bpy.context.scene
sc.render.fps = FPS
sc.render.fps_base = 1.0
skel = bpy.data.objects["THETA_Skeleton"]
skel.animation_data_create()
bones = skel.data.bones


def depth(b):
    d = 0
    while b.parent:
        d += 1
        b = b.parent
    return d


ORDER = sorted(bones, key=depth)
REST = {b.name: b.matrix_local.to_quaternion() for b in bones}


def new_action(name):
    old = bpy.data.actions.get(name)
    if old:
        bpy.data.actions.remove(old)
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    skel.animation_data.action = act
    PREV.clear()
    return act


PREV = {}


def key_all(frame, names=None):
    for pb in skel.pose.bones:
        if names is not None and pb.name not in names:
            continue
        q = pb.rotation_quaternion
        p = PREV.get(pb.name)
        if p is not None and p.dot(q) < 0:
            pb.rotation_quaternion = -q
        PREV[pb.name] = pb.rotation_quaternion.copy()
        pb.keyframe_insert("rotation_quaternion", frame=frame)
        if pb.name == "DEF-spine":
            pb.keyframe_insert("location", frame=frame)


def finish(act, frame_end, cyclic):
    act.frame_range = (0, frame_end)
    act.use_frame_range = True
    act.use_cyclic = cyclic
    for fc in iter_fcurves(act):
        for kp in fc.keyframe_points:
            kp.interpolation = "BEZIER"
    skel.animation_data.action = None


def iter_fcurves(act):
    if hasattr(act, "fcurves") and len(getattr(act, "fcurves", [])):
        yield from act.fcurves
        return
    for layer in getattr(act, "layers", []):
        for strip in layer.strips:
            for bag in strip.channelbags:
                yield from bag.fcurves


def update():
    bpy.context.view_layer.update()


def parent_delta(name):
    pb = skel.pose.bones[name]
    if pb.parent is None:
        return Quaternion()
    return pb.parent.matrix.to_quaternion() @ REST[pb.parent.name].inverted()


def aim(name, direction, twist=0.0):
    """Point bone `name` along `direction` (armature axes), on top of its parent's pose."""
    update()
    b = bones[name]
    P = parent_delta(name)
    rest_dir = (b.tail_local - b.head_local).normalized()
    cur = P @ rest_dir
    W = cur.rotation_difference(Vector(direction).normalized())
    if twist:
        W = Quaternion(Vector(direction).normalized(), math.radians(twist)) @ W
    set_rot(skel, name, q=P.inverted() @ W @ P)


def rot_world(name, x=0.0, y=0.0, z=0.0):
    """Extra rotation in character axes on top of what the bone inherits from its parent."""
    update()
    P = parent_delta(name)
    set_rot(skel, name, q=P.inverted() @ arm_quat(x, y, z) @ P)


def mirror_dir(d):
    return Vector((-d[0], d[1], d[2]))


def arms_down(spread=0.22, fwd=0.02, elbow_bend=12, side="LR"):
    for s in side:
        sx = 1 if s == "L" else -1
        aim(f"DEF-upper_arm.{s}", (sx * spread, fwd, -1.0))
        update()
        # bend elbow forward a little
        d = Vector((sx * spread * 0.6, -math.sin(math.radians(elbow_bend)), -1.0))
        aim(f"DEF-forearm.{s}", d)


# ======================================================================= mocap retarget
SRC_MAP = {
    "Hips": "DEF-spine",
    "Spine1": "DEF-spine.001",
    "Spine2": "DEF-spine.002",
    "Spine4": "DEF-spine.003",
    "Neck": "DEF-spine.004",
    "Head": "DEF-spine.006",
}
for side, s in (("Left", "L"), ("Right", "R")):
    SRC_MAP.update({
        f"{side}Shoulder": f"DEF-shoulder.{s}",
        f"{side}Arm": f"DEF-upper_arm.{s}",
        f"{side}ForeArm": f"DEF-forearm.{s}",
        f"{side}Hand": f"DEF-hand.{s}",
        f"{side}Thigh": f"DEF-thigh.{s}",
        f"{side}Shin": f"DEF-shin.{s}",
        f"{side}Foot": f"DEF-foot.{s}",
        f"{side}Toe": f"DEF-toe.{s}",
    })
# which child marks the "pointing direction" of a source bone
SRC_CHILD = {
    "Hips": "Spine1", "Spine1": "Spine2", "Spine2": "Spine3", "Spine4": "Neck", "Neck": "Head",
}
for side in ("Left", "Right"):
    SRC_CHILD.update({
        f"{side}Shoulder": f"{side}Arm", f"{side}Arm": f"{side}ForeArm",
        f"{side}ForeArm": f"{side}Hand", f"{side}Thigh": f"{side}Shin",
        f"{side}Shin": f"{side}Foot", f"{side}Foot": f"{side}Toe",
    })
TGT_DIR_BONE = {  # target bone whose head->tail (or to child head) gives the direction
    "DEF-thigh.L": ("DEF-thigh.L", "DEF-shin.L"), "DEF-thigh.R": ("DEF-thigh.R", "DEF-shin.R"),
    "DEF-shin.L": ("DEF-shin.L", "DEF-foot.L"), "DEF-shin.R": ("DEF-shin.R", "DEF-foot.R"),
    "DEF-upper_arm.L": ("DEF-upper_arm.L", "DEF-forearm.L"),
    "DEF-upper_arm.R": ("DEF-upper_arm.R", "DEF-forearm.R"),
    "DEF-forearm.L": ("DEF-forearm.L", "DEF-hand.L"), "DEF-forearm.R": ("DEF-forearm.R", "DEF-hand.R"),
    "DEF-spine.004": ("DEF-spine.004", "DEF-spine.006"),
    "DEF-spine": ("DEF-spine", "DEF-spine.001"),
    "DEF-spine.003": ("DEF-spine.003", "DEF-spine.004"),
}


def tgt_dir(name):
    a, b = TGT_DIR_BONE.get(name, (name, None))
    if b:
        return (bones[b].head_local - bones[a].head_local).normalized()
    bb = bones[a]
    return (bb.tail_local - bb.head_local).normalized()


def import_mocap(fname):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=os.path.join(MOCAP, fname), automatic_bone_orientation=False)
    new = [o for o in bpy.data.objects if o not in before]
    arm = next(o for o in new if o.type == "ARMATURE")
    return arm, new


def src_world_rot(arm, fix, name):
    return (fix @ arm.matrix_world @ arm.pose.bones[name].matrix).to_quaternion()


def src_world_head(arm, fix, name):
    return fix @ arm.matrix_world @ arm.pose.bones[name].head


def src_rest(arm, fix, name):
    m = fix @ arm.matrix_world @ arm.data.bones[name].matrix_local
    return m.to_quaternion(), m.translation.copy()


def pose_signature(arm, names):
    return [arm.pose.bones[n].matrix_basis.to_quaternion().copy() for n in names]


def sig_dist(a, b):
    return sum(1 - abs(x.dot(y)) for x, y in zip(a, b))


def find_loop(arm, start_range, period_range):
    names = [n for n in ("LeftThigh", "RightThigh", "LeftShin", "RightShin", "LeftArm", "RightArm", "Hips")
             if n in arm.pose.bones]
    cache = {}

    def sig(f):
        if f not in cache:
            sc.frame_set(f)
            cache[f] = pose_signature(arm, names)
        return cache[f]
    best = None
    for s in range(*start_range):
        for p in range(*period_range):
            d = sig_dist(sig(s), sig(s + p))
            if best is None or d < best[0]:
                best = (d, s, p)
    return best


UPPER = None


def retarget(fname, act_name, start_range, period_range, speed=1.0, lean=0.0):
    global UPPER
    if UPPER is None:
        UPPER = set()
        for b in bones:
            p = b
            while p:
                if p.name == "DEF-spine" and not any(k in b.name for k in ("thigh", "shin", "foot", "toe")):
                    UPPER.add(b.name)
                    break
                p = p.parent
    arm, new_objs = import_mocap(fname)
    act = arm.animation_data.action
    print("mocap", fname, "frames", tuple(act.frame_range))
    sc.frame_set(int(act.frame_range[0]))
    # facing fix: target left leg is +X. Mocap must match.
    fix = Matrix.Identity(4)
    sc.frame_set(1)
    lx = (arm.matrix_world @ arm.data.bones["LeftThigh"].head_local).x
    if lx < 0:
        fix = Matrix.Rotation(math.pi, 4, "Z")
    # alignment offsets at rest
    O = {}
    for s_name, t_name in SRC_MAP.items():
        if s_name not in arm.data.bones:
            print("  missing source bone", s_name)
            continue
        child = SRC_CHILD.get(s_name)
        if child and child in arm.data.bones:
            ds = (fix @ arm.matrix_world @ arm.data.bones[child].head_local) - \
                 (fix @ arm.matrix_world @ arm.data.bones[s_name].head_local)
            O[s_name] = ds.normalized().rotation_difference(tgt_dir(t_name))
        else:
            O[s_name] = None  # filled from parent below
    for s_name in SRC_MAP:
        if s_name in O and O[s_name] is None:
            p = arm.data.bones[s_name].parent
            while p and (p.name not in O or O[p.name] is None):
                p = p.parent
            O[s_name] = O[p.name] if p else Quaternion()
    rest_q = {n: src_rest(arm, fix, n)[0] for n in O}
    hip_rest = src_rest(arm, fix, "Hips")[1]
    scale = bones["DEF-spine"].head_local.z / hip_rest.z
    print("  height scale", round(scale, 3), "facing fix", lx < 0)

    d, s0, period = find_loop(arm, start_range, period_range)
    print("  loop start", s0, "period", period, "err", round(d, 4))

    # The performer doesn't face the same way as the T-pose during the take: find the average
    # facing of the hips over the loop and turn the whole take so it walks toward -Y.
    frames = list(range(s0, s0 + period + 1))
    favg = Vector()
    for f in frames:
        sc.frame_set(f)
        dq = src_world_rot(arm, fix, "Hips") @ rest_q["Hips"].inverted()
        fw = dq @ Vector((0, -1, 0))
        favg += Vector((fw.x, fw.y, 0))
    yaw = favg.normalized().rotation_difference(Vector((0, -1, 0)))
    print("  facing correction (deg)", round(math.degrees(yaw.angle), 1))
    fix_anim = yaw.to_matrix().to_4x4() @ fix

    # sample
    samples = []
    hips = []
    for f in frames:
        sc.frame_set(f)
        want = {}
        for s_name, t_name in SRC_MAP.items():
            if s_name not in O:
                continue
            Ws = src_world_rot(arm, fix_anim, s_name)
            delta = Ws @ rest_q[s_name].inverted() @ O[s_name].inverted()
            want[t_name] = delta @ REST[t_name]
            if lean and t_name in UPPER:
                want[t_name] = arm_quat(x=lean) @ want[t_name]
        samples.append(want)
        hips.append(src_world_head(arm, fix_anim, "Hips"))
    mean = sum(hips, Vector()) / len(hips)

    new_action(act_name)
    reset(skel)
    for i, (f, want) in enumerate(zip(frames, samples)):
        if i == len(frames) - 1:
            want = samples[0]  # exact loop
            hip = hips[0]
        else:
            hip = hips[i]
        pose_rot = {}
        for b in ORDER:
            n = b.name
            if b.parent is None:
                pose_rot[n] = REST[n]
                continue
            pr = pose_rot[b.parent.name]
            if n in want:
                pose_rot[n] = want[n]
            else:
                pose_rot[n] = pr @ REST[b.parent.name].inverted() @ REST[n]
            basis = REST[n].inverted() @ REST[b.parent.name] @ pr.inverted() @ pose_rot[n]
            pb = skel.pose.bones[n]
            pb.rotation_mode = "QUATERNION"
            pb.rotation_quaternion = basis
        off = (hip - mean) * scale
        off.z = (hip.z - hip_rest.z) * scale  # bob + crouch relative to standing height
        off.x *= 0.5  # keep a little side sway
        off.y = 0.0   # in place (the controller moves the body)
        set_loc(skel, "DEF-spine", off)
        t = (f - s0) / 30.0 / speed
        key_all(t * FPS)
    end = period / 30.0 / speed * FPS
    finish(bpy.data.actions[act_name], end, True)
    # quaternion continuity
    for o in new_objs:
        bpy.data.objects.remove(o, do_unlink=True)
    for a in list(bpy.data.actions):
        if a.users == 0 and not a.name.startswith("THETA_"):
            bpy.data.actions.remove(a)
    print("  ->", act_name, "length", round(period / 30.0 / speed, 3), "s")


# ======================================================================= hand-keyed
def pose_idle(phase):
    reset(skel)
    b = math.sin(phase * 2 * math.pi)
    set_rot(skel, "DEF-spine", x=2)
    set_rot(skel, "DEF-spine.001", x=-(1 + 0.6 * b))
    set_rot(skel, "DEF-spine.003", x=-1.2 * b)
    set_rot(skel, "DEF-spine.006", x=-(-3 - 1.0 * b), z=0)
    set_loc(skel, "DEF-spine", (0, 0, -0.012 + 0.006 * b))
    for s, sx in (("L", 1), ("R", -1)):
        set_rot(skel, f"DEF-thigh.{s}", x=-3, y=sx * 2)
        set_rot(skel, f"DEF-shin.{s}", x=6)
        set_rot(skel, f"DEF-foot.{s}", x=-3)
        set_rot(skel, f"DEF-shoulder.{s}", y=sx * (1.5 * b))
    arms_down(spread=0.30, fwd=0.04, elbow_bend=14 + 2 * b)


def make_idle():
    new_action("THETA_Idle")
    n = 4
    length = 3.0
    for i in range(n + 1):
        pose_idle(i / n)
        key_all(i * length / n * FPS)
    finish(bpy.data.actions["THETA_Idle"], length * FPS, True)


def pose_takeoff():
    """Launch frame: body stretched up, arms swung up, toes pointed."""
    reset(skel)
    set_rot(skel, "DEF-spine", x=-4)
    set_rot(skel, "DEF-spine.003", x=-6)
    set_rot(skel, "DEF-spine.006", x=-8)
    for s, sx in (("L", 1), ("R", -1)):
        set_rot(skel, f"DEF-thigh.{s}", x=-6 if s == "L" else 4, y=sx * 2)
        set_rot(skel, f"DEF-shin.{s}", x=10 if s == "L" else 4)
        set_rot(skel, f"DEF-foot.{s}", x=40)
    update()
    for s in "LR":
        sx = 1 if s == "L" else -1
        aim(f"DEF-upper_arm.{s}", (sx * 0.35, -0.35, 1.0))
        aim(f"DEF-forearm.{s}", (sx * 0.25, -0.45, 1.0))


def pose_tuck():
    reset(skel)
    set_rot(skel, "DEF-spine", x=30)
    set_rot(skel, "DEF-spine.001", x=18)
    set_rot(skel, "DEF-spine.002", x=15)
    set_rot(skel, "DEF-spine.003", x=12)
    set_rot(skel, "DEF-spine.004", x=10)
    set_rot(skel, "DEF-spine.006", x=20)
    for s, sx in (("L", 1), ("R", -1)):
        set_rot(skel, f"DEF-thigh.{s}", x=-95, y=sx * 6)
        set_rot(skel, f"DEF-shin.{s}", x=145)
        set_rot(skel, f"DEF-foot.{s}", x=35)
    update()
    # hug the shins
    for s in "LR":
        sx = 1 if s == "L" else -1
        aim(f"DEF-upper_arm.{s}", (sx * 0.35, -0.75, -0.55))
        aim(f"DEF-forearm.{s}", (-sx * 0.35, -0.55, -0.75))


def make_jump():
    new_action("THETA_JumpTuck")
    pose_takeoff()
    key_all(0)
    pose_tuck()
    key_all(7)       # into the ball fast
    key_all(18)
    finish(bpy.data.actions["THETA_JumpTuck"], 18, False)


def pose_dive():
    reset(skel)
    set_rot(skel, "DEF-spine", x=-6)
    set_rot(skel, "DEF-spine.001", x=-4)
    set_rot(skel, "DEF-spine.003", x=-4)
    set_rot(skel, "DEF-spine.006", x=10)
    for s, sx in (("L", 1), ("R", -1)):
        set_rot(skel, f"DEF-thigh.{s}", x=8, y=sx * 2)
        set_rot(skel, f"DEF-shin.{s}", x=18)
        set_rot(skel, f"DEF-foot.{s}", x=40)
    update()
    for s in "LR":
        sx = 1 if s == "L" else -1
        aim(f"DEF-upper_arm.{s}", (sx * 0.22, -0.25, 1.0))
        aim(f"DEF-forearm.{s}", (sx * 0.12, -0.2, 1.0))


def make_dive():
    new_action("THETA_Dive")
    pose_dive()
    key_all(0)
    set_rot(skel, "DEF-spine.001", x=-7)
    key_all(15)
    pose_dive()
    key_all(30)
    finish(bpy.data.actions["THETA_Dive"], 30, True)


def pose_fall(b):
    reset(skel)
    set_rot(skel, "DEF-spine", x=6)
    set_rot(skel, "DEF-spine.006", x=6)
    for s, sx in (("L", 1), ("R", -1)):
        set_rot(skel, f"DEF-thigh.{s}", x=-25 + (8 * b if s == "L" else -8 * b), y=sx * 6)
        set_rot(skel, f"DEF-shin.{s}", x=40)
        set_rot(skel, f"DEF-foot.{s}", x=15)
    update()
    for s in "LR":
        sx = 1 if s == "L" else -1
        aim(f"DEF-upper_arm.{s}", (sx * 1.0, 0.1, 0.15 + 0.1 * b))
        aim(f"DEF-forearm.{s}", (sx * 1.0, -0.1, 0.35 + 0.1 * b))


def make_fall():
    new_action("THETA_Fall")
    for i, b in enumerate((0, 1, 0)):
        pose_fall(b)
        key_all(i * 12)
    finish(bpy.data.actions["THETA_Fall"], 24, True)


ARM_R = None


def pose_aim(recoil=0.0):
    reset(skel)
    set_rot(skel, "DEF-shoulder.R", z=-6)
    update()
    aim("DEF-upper_arm.R", (0.08, -1.0, 0.02 + recoil * 0.15))
    aim("DEF-forearm.R", (0.10, -1.0, 0.03 + recoil * 0.5))
    # The right hand is a finger-gun: point the index finger straight down the aim line.
    update()
    i1, i3 = bones["DEF-f_index.01.R"], bones["DEF-f_index.03.R"]
    barrel_rest = (i3.tail_local - i1.head_local).normalized()
    P = parent_delta("DEF-hand.R")
    cur = P @ barrel_rest
    target = arm_quat(x=-recoil * 35) @ Vector((0.06, -1.0, 0.0)).normalized()
    W = cur.rotation_difference(target)
    set_rot(skel, "DEF-hand.R", q=P.inverted() @ W @ P)


def make_aim():
    global ARM_R
    ARM_R = [b.name for b in bones if b.name.endswith(".R") and any(
        k in b.name for k in ("shoulder", "upper_arm", "forearm", "hand", "f_", "thumb", "palm"))]
    new_action("THETA_Aim")
    pose_aim(0)
    key_all(0, ARM_R)
    key_all(1, ARM_R)
    finish(bpy.data.actions["THETA_Aim"], 1, False)
    new_action("THETA_Recoil")
    pose_aim(0)
    key_all(0, ARM_R)
    pose_aim(1.0)
    key_all(2, ARM_R)
    pose_aim(0)
    key_all(8, ARM_R)
    finish(bpy.data.actions["THETA_Recoil"], 8, False)


# ======================================================================= run
def pose_crouch(b=0.0):
    """Low ready crouch. Hips drop and slide back so the feet stay planted."""
    reset(skel)
    set_loc(skel, "DEF-spine", (0, 0.24, -0.25 - 0.01 * b))
    set_rot(skel, "DEF-spine.001", x=22)
    set_rot(skel, "DEF-spine.003", x=6 + b)
    set_rot(skel, "DEF-spine.006", x=-18)
    for s, sx in (("L", 1), ("R", -1)):
        set_rot(skel, f"DEF-thigh.{s}", x=-50, y=sx * 8)
        set_rot(skel, f"DEF-shin.{s}", x=80)
        set_rot(skel, f"DEF-foot.{s}", x=-30)
    update()
    for s in "LR":
        sx = 1 if s == "L" else -1
        aim(f"DEF-upper_arm.{s}", (sx * 0.3, -0.35, -1.0))
        aim(f"DEF-forearm.{s}", (sx * 0.1, -0.8, -0.4))


def make_crouch():
    new_action("THETA_Crouch")
    for i, b in enumerate((0, 1, 0)):
        pose_crouch(b)
        key_all(i * 30)
    finish(bpy.data.actions["THETA_Crouch"], 60, True)


def make_roll():
    """Tight ball held for the whole ground roll (no take-off frame)."""
    new_action("THETA_Roll")
    pose_tuck()
    set_rot(skel, "DEF-spine.006", x=30)   # chin tucked so the head doesn't hit first
    key_all(0)
    key_all(10)
    finish(bpy.data.actions["THETA_Roll"], 10, True)


make_idle()
make_roll()
make_crouch()
make_jump()
make_dive()
make_fall()
make_aim()
retarget("02-walkforward.fbx", "THETA_Walk", (120, 150), (26, 46), lean=3)
retarget("05-running-treadmill.fbx", "THETA_Run", (190, 215), (15, 30), lean=16)

reset(skel)
skel.animation_data.action = None
sc.frame_set(0)
for a in list(bpy.data.actions):
    if not a.name.startswith("THETA_"):
        a.use_fake_user = False
print("actions:", [(a.name, tuple(a.frame_range)) for a in bpy.data.actions if a.name.startswith("THETA_")])
bpy.ops.wm.save_mainfile()
print("saved", bpy.data.filepath)
