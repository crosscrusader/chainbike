"""Render a quick check image of THETA in a test pose.
blender -b THETA2_game.blend --python render_check.py -- out.png pose [view]
"""
import bpy, sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
from posing import set_rot, reset
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
out, pose = argv[0], argv[1]
view = argv[2] if len(argv) > 2 else "side"
frame = int(argv[3]) if len(argv) > 3 else None
skel = bpy.data.objects["THETA_Skeleton"]
sc = bpy.context.scene
if frame is not None:
    act = bpy.data.actions.get(pose)
    skel.animation_data_create()
    skel.animation_data.action = act
    if act and act.slots:
        skel.animation_data.action_slot = act.slots[0]
    sc.frame_set(frame)
else:
    if skel.animation_data:
        skel.animation_data.action = None
    reset(skel)
    if pose == "knee":
        set_rot(skel, "DEF-thigh.L", x=-60)
        set_rot(skel, "DEF-shin.L", x=90)
    elif pose == "elbow":
        set_rot(skel, "DEF-upper_arm.L", y=-40)
        set_rot(skel, "DEF-forearm.L", z=100)
    sc.frame_set(1)

cam = bpy.data.objects.get("Camera")
target = Vector((0, 0, 1.0))
dist = 3.2
if view == "side":
    pos = Vector((dist, 0, 1.0))
elif view == "front":
    pos = Vector((0, -dist, 1.1))
elif view == "legs":
    pos = Vector((3, 0, 0.6)); target = Vector((0, 0, 0.6))
elif view == "q":
    pos = Vector((dist * 0.7, -dist * 0.7, 1.3))
cam.location = pos
cam.rotation_euler = (target - pos).to_track_quat("-Z", "Y").to_euler()
cam.data.lens = 50
cam.data.type = "PERSP"
if view in ("side", "legs"):
    cam.data.type = "ORTHO"; cam.data.ortho_scale = 1.6 if view == "legs" else 2.4
sc.camera = cam
sc.render.resolution_x = 700
sc.render.resolution_y = 900
sc.render.resolution_percentage = 100
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
print("wrote", out)
