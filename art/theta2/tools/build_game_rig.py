"""Build a game-ready, deform-only skeleton for THETA and bind every mesh to it.

Run:  blender -b art/theta2/THETA2_fixed.blend --python art/theta2/tools/build_game_rig.py

What it does
  * Creates "THETA_Skeleton": a copy of every DEF- bone of the Rigify "rig", with the same
    rest matrices (so existing weights still line up), no B-Bone segments (Godot can't
    do B-Bones), and a clean parent hierarchy under a "root" bone.
  * Removes every Armature modifier pointing at "rig" or the old "rig.001" and binds the
    mesh to THETA_Skeleton instead. This also rebinds Cube.006-.010/.012 (collar/torso),
    which were still on rig.001.
  * Vertices with no DEF- weight (only ORG-/MCH-/control groups that rig.001 used) get those
    weights remapped onto the matching DEF- bone.
  * Smooths the knee/elbow weights so the bend keeps its volume without B-Bones.
  * Saves the result as THETA2_game.blend next to the source file.
The Rigify rig is kept (hidden) so the file can still be opened and inspected.
"""
import bpy, re, os
from mathutils import Vector

SRC_RIG = "rig"
OLD_RIG = "rig.001"
SKEL = "THETA_Skeleton"

rig = bpy.data.objects[SRC_RIG]
deform = [b for b in rig.data.bones if b.use_deform]
deform_names = {b.name for b in deform}


def fallback_parent(name):
    if re.match(r"DEF-(pelvis|thigh)\.", name):
        return "DEF-spine"
    if re.match(r"DEF-(shoulder|breast)\.", name):
        return "DEF-spine.003"
    m = re.match(r"DEF-upper_arm\.([LR])$", name)
    if m:
        return "DEF-shoulder." + m.group(1)
    if name == "DEF-spine":
        return "root"
    return "DEF-spine.006"  # face bones


def def_parent(b):
    p = b.parent
    while p is not None and not p.use_deform:
        p = p.parent
    return p.name if p else fallback_parent(b.name)


# ---------------------------------------------------------------- skeleton
if SKEL in bpy.data.objects:
    bpy.data.objects.remove(bpy.data.objects[SKEL])
arm_data = bpy.data.armatures.new(SKEL)
skel = bpy.data.objects.new(SKEL, arm_data)
bpy.context.scene.collection.objects.link(skel)
skel.matrix_world = rig.matrix_world.copy()

bpy.context.view_layer.objects.active = skel
for o in bpy.context.selected_objects:
    o.select_set(False)
skel.select_set(True)
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_data.edit_bones
root = eb.new("root")
root.head = Vector((0, 0, 0))
root.tail = Vector((0, 0.25, 0))
root.roll = 0
for b in deform:
    e = eb.new(b.name)
    e.head = b.head_local
    e.tail = b.tail_local
    e.matrix = b.matrix_local  # keeps roll exactly
    e.bbone_segments = 1
    e.use_deform = True
for b in deform:
    e = eb[b.name]
    e.parent = eb[def_parent(b)]
    e.use_connect = False
root.use_deform = False
bpy.ops.object.mode_set(mode="OBJECT")
print("skeleton bones:", len(arm_data.bones))

# ---------------------------------------------------------------- weights
STRIP = ("ORG-", "MCH-", "DEF-", "STR-", "ROT-", "WGT-", "tweak_", "INT-")
ALIASES = {
    "neck": "DEF-spine.004", "head": "DEF-spine.006", "chest": "DEF-spine.003",
    "hips": "DEF-spine", "torso": "DEF-spine", "spine_fk": "DEF-spine",
}


def map_group(name):
    if name in deform_names:
        return name
    n = name
    changed = True
    while changed:
        changed = False
        for s in STRIP:
            if n.startswith(s):
                n = n[len(s):]
                changed = True
    n = n.replace("_fk", "").replace("_ik", "")
    if "DEF-" + n in deform_names:
        return "DEF-" + n
    base = n.split(".")[0]
    if base in ALIASES:
        return ALIASES[base]
    if n in ALIASES:
        return ALIASES[n]
    return None


def remap_weights(obj):
    vgs = obj.vertex_groups
    idx_name = {g.index: g.name for g in vgs}
    fixed = 0
    for v in obj.data.vertices:
        def_total = sum(g.weight for g in v.groups if idx_name[g.group] in deform_names)
        if def_total > 1e-4:
            continue
        acc = {}
        for g in v.groups:
            if g.weight <= 0:
                continue
            t = map_group(idx_name[g.group])
            if t:
                acc[t] = acc.get(t, 0) + g.weight
        if not acc:
            continue
        fixed += 1
        for t, w in acc.items():
            grp = vgs.get(t) or vgs.new(name=t)
            grp.add([v.index], w, "REPLACE")
    return fixed


def has_arm_mod(o):
    return any(m.type == "ARMATURE" for m in o.modifiers)


meshes = [o for o in bpy.data.objects if o.type == "MESH" and has_arm_mod(o)]
for o in meshes:
    mods = list(o.modifiers)
    first = next(i for i, m in enumerate(mods) if m.type == "ARMATURE")
    for m in mods:
        if m.type == "ARMATURE":
            o.modifiers.remove(m)
    fixed = remap_weights(o)
    am = o.modifiers.new("Skeleton", "ARMATURE")
    am.object = skel
    am.use_vertex_groups = True
    am.use_bone_envelopes = False
    am.use_deform_preserve_volume = False  # glTF/Godot use linear blend skinning
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.modifier_move_to_index(modifier=am.name, index=first)
    mw = o.matrix_world.copy()
    o.parent = skel
    o.parent_type = "OBJECT"
    o.matrix_world = mw
    print("bound", o.name, "remapped verts:", fixed)

# Face-normal proxy follows the head bone of the new skeleton.
fnp = bpy.data.objects.get("FaceNormalProxy")
if fnp:
    mw = fnp.matrix_world.copy()
    fnp.parent = skel
    fnp.parent_type = "BONE"
    fnp.parent_bone = "DEF-spine.006"
    fnp.matrix_world = mw


# ---------------------------------------------------------------- knee / elbow smoothing
# Without B-Bones the joint verts snap between two bones and the shin collapses at the knee.
# Spread the weights over a short band around each hinge so the bend stays round.
JOINTS = [
    ("DEF-thigh.{s}.001", "DEF-shin.{s}", 0.07),
    ("DEF-shin.{s}", "DEF-shin.{s}.001", 0.06),
    ("DEF-thigh.{s}", "DEF-thigh.{s}.001", 0.06),
    ("DEF-upper_arm.{s}.001", "DEF-forearm.{s}", 0.05),
    ("DEF-upper_arm.{s}", "DEF-upper_arm.{s}.001", 0.04),
    ("DEF-forearm.{s}", "DEF-forearm.{s}.001", 0.04),
]

if os.environ.get("THETA_NO_SMOOTH"):
    JOINTS = []


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def smooth_joint(obj, a_name, b_name, radius):
    bones = skel.data.bones
    if a_name not in bones or b_name not in bones:
        return 0
    vga, vgb = obj.vertex_groups.get(a_name), obj.vertex_groups.get(b_name)
    if vga is None and vgb is None:
        return 0
    vga = vga or obj.vertex_groups.new(name=a_name)
    vgb = vgb or obj.vertex_groups.new(name=b_name)
    bb = bones[b_name]
    hinge = skel.matrix_world @ bb.head_local
    axis = ((skel.matrix_world @ bb.tail_local) - hinge).normalized()
    mw = obj.matrix_world
    n = 0
    for v in obj.data.vertices:
        wa = wb = 0.0
        for g in v.groups:
            if g.group == vga.index:
                wa = g.weight
            elif g.group == vgb.index:
                wb = g.weight
        pair = wa + wb
        if pair < 1e-4:
            continue
        p = mw @ v.co
        d = (p - hinge).dot(axis)  # signed distance along the lower bone (world units)
        if abs(d) > radius:
            continue
        radial = ((p - hinge) - axis * d).length
        if radial > 0.16:
            continue
        tb = smoothstep(-radius, radius, d)
        vga.add([v.index], pair * (1 - tb), "REPLACE")
        vgb.add([v.index], pair * tb, "REPLACE")
        n += 1
    return n


for o in meshes:
    if o.name in ("Cube.002", "Cube.005"):
        continue
    for a, b, r in JOINTS:
        for s in ("L", "R"):
            c = smooth_joint(o, a.format(s=s), b.format(s=s), r)
            if c:
                print("  smoothed", o.name, a.format(s=s), "->", b.format(s=s), c)

# Rigid armour pieces: the shin guard (Cube.002) and its straps (Cube.005) had part of their
# top edge weighted to the thigh, so bending the knee dragged the guard up the thigh and the
# shin looked like it collapsed. They are hard plates, so bind them 100% to the shin.
# (Mirror modifier turns the .L group into .R for the other leg.)
RIGID = {"Cube.002": "DEF-shin.L", "Cube.005": "DEF-shin.L"}
for oname, bone in RIGID.items():
    o = bpy.data.objects.get(oname)
    if not o:
        continue
    allv = [v.index for v in o.data.vertices]
    for g in list(o.vertex_groups):
        if g.name in deform_names:
            g.remove(allv)
    tg = o.vertex_groups.get(bone) or o.vertex_groups.new(name=bone)
    tg.add(allv, 1.0, "REPLACE")
    print("rigid", oname, "->", bone)

# old rigs out of the way (kept for reference, never exported)
for name in (SRC_RIG, OLD_RIG, "metarig.001"):
    ob = bpy.data.objects.get(name)
    if ob:
        try:
            ob.hide_set(True)
        except RuntimeError:
            pass
        ob.hide_render = True
        ob.hide_viewport = True

out = os.environ.get("THETA_OUT") or os.path.join(os.path.dirname(bpy.data.filepath), "THETA2_game.blend")
bpy.ops.wm.save_as_mainfile(filepath=out, copy=False)
print("saved", out)
