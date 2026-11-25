"""Export THETA (skeleton + skinned meshes + actions) to the Godot project as a .glb.

blender -b art/theta2/THETA2_game.blend --python art/theta2/tools/export_glb.py
Writes assets/characters/theta/theta.glb
"""
import bpy, os

here = os.path.dirname(bpy.data.filepath)
out = os.environ.get("THETA_GLB") or os.path.normpath(
    os.path.join(here, "..", "..", "assets", "characters", "theta", "theta.glb"))
os.makedirs(os.path.dirname(out), exist_ok=True)

skel = bpy.data.objects["THETA_Skeleton"]
# rest pose for the mesh bind; actions are exported separately
if skel.animation_data:
    skel.animation_data.action = None
for pb in skel.pose.bones:
    pb.matrix_basis.identity()

for o in bpy.context.view_layer.objects:
    o.select_set(False)
export = [skel] + [c for c in skel.children
                   if c.type == "MESH" and not c.hide_render and c.name != "FaceNormalProxy"]
for o in export:
    try:
        o.hide_set(False)
    except RuntimeError:
        pass
    o.hide_viewport = False
    o.select_set(True)
bpy.context.view_layer.objects.active = skel
print("exporting:", [o.name for o in export])

# Only the THETA_ actions are game animations.
for a in list(bpy.data.actions):
    if not a.name.startswith("THETA_"):
        a.use_fake_user = False

kw = dict(
    filepath=out,
    export_format="GLB",
    use_selection=True,
    export_apply=True,             # mirror / solidify (outline shell) / smooth-by-angle / normal transfer
    export_normals=True,           # custom split normals survive
    export_tangents=False,
    export_texcoords=True,
    export_materials="EXPORT",
    export_image_format="AUTO",
    export_skins=True,
    export_all_influences=False,   # 4 weights per vertex
    export_def_bones=False,        # skeleton is already deform-only (+root)
    export_animations=True,
    export_animation_mode="ACTIONS",
    export_force_sampling=True,
    export_frame_step=1,
    export_anim_single_armature=True,
    export_reset_pose_bones=True,
    export_morph=False,
    export_yup=True,
    export_extras=False,
    export_lights=False,
    export_cameras=False,
)
# drop options this Blender build doesn't know
props = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
kw = {k: v for k, v in kw.items() if k in props}
bpy.ops.export_scene.gltf(**kw)
print("wrote", out)
