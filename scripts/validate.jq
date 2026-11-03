# Schema and policy validation for images/*.yaml.
#
# Invoked as: jq -r -f validate.jq --arg file ... <document>
# Emits one "<file>: <message>" line per violation and nothing otherwise.
#
# Kept as a jq program rather than a pile of `yq -r` calls so the whole
# document is available for cross-field checks (target prefix vs destination,
# duplicate versions, platform overrides, ...).

def tag_ok: test("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$");
def digest_ok: test("^sha256:[a-f0-9]{64}$");
def ref_ok: test("^[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9._/-]+$");
def name_ok: test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$");
def plat_ok: test("^[a-z0-9]+/[a-z0-9]+(/[a-z0-9]+)?$");
def no_tag_or_digest: (test("@") | not) and ((split("/") | .[-1] | test(":")) | not);
def msg: "\($file): \(.)";

. as $d
| ($d.spec.images // []) as $images
| ($d.spec.defaults.platforms // $defaultPlatforms) as $defaults
| [

    # --- document ---------------------------------------------------------
    (if ($d.apiVersion // "") != $api
      then "apiVersion must be \($api)"
      else empty end),

    (if ($d.kind // "") != "ImageMirrorList"
      then "kind must be ImageMirrorList"
      else empty end),

    (if ($d.metadata.name // "") == ""
      then "metadata.name is required"
      elif ($d.metadata.name | name_ok | not)
      then "metadata.name must be kebab-case"
      elif $d.metadata.name != ($file | sub("\\.yaml$"; ""))
      then "metadata.name must match the file name (\($file))"
      else empty end),

    (if ($images | length) == 0
      then "spec.images must contain at least one image"
      else empty end),

    # --- per image --------------------------------------------------------
    ( $images[] as $img
      | ($img.name // "<unnamed>") as $n
      | ($img.source // "") as $s
      | ($img.target // "") as $t
      | ($t | split("/")) as $tp
      | ($destinations | map(select(.host == $tp[0])) | .[0] // {}) as $dest
      | (

          (if ($n | name_ok | not)
            then "\($n): name must be kebab-case"
            else empty end),

          (if $s == ""
            then "\($n): source is required"
            elif ($s | ref_ok | not)
            then "\($n): source must look like <host>/<path>"
            elif ($s | no_tag_or_digest | not)
            then "\($n): source must not embed a tag or digest; use versions[]"
            elif ($sources | index($s | split("/")[0])) == null
            then "\($n): source host \($s | split("/")[0]) is not declared in config/registries.yaml"
            else empty end),

          (if $t == ""
            then "\($n): target is required"
            elif ($t | ref_ok | not)
            then "\($n): target must look like <host>/<project>/<path>"
            elif ($t | no_tag_or_digest | not)
            then "\($n): target must not embed a tag or digest; use versions[]"
            elif $dest.host == null
            then "\($n): target host \($tp[0]) is not a configured destination"
            elif ($tp | length) < 4
            then "\($n): target must include <project>/<source-host>/<path>"
            elif $tp[1] != $dest.project
            then "\($n): target must live under the '\($dest.project)' project, got '\($tp[1])'"
            elif ($requireHost == "true") and ($tp[2] != ($s | split("/")[0]))
            then "\($n): target must embed the source host '\($s | split("/")[0])' at position 3, got '\($tp[2])'"
            else empty end),

          ( ($img.versions // []) as $versions
            | (if ($versions | length) == 0
                then "\($n): versions[] must not be empty"
                else empty end),
              ( $versions[] as $ver
                | ($ver.tag // "") as $tag
                | (if ($tag | tag_ok | not)
                    then "\($n): invalid or missing tag: \($tag | tostring)"
                    elif ($tag == "latest") and ($allowLatest != "true")
                    then "\($n): refusing the floating tag 'latest'; pin a release instead"
                    else empty end),
                  (if ($ver.digest // "") != "" and (($ver.digest | digest_ok) | not)
                    then "\($n):\($tag): digest must be sha256:<64 lowercase hex>"
                    else empty end) ) ),

          ( ($img.platforms // $defaults) as $platforms
            | (if ($platforms | length) == 0
                then "\($n): platforms must not be empty"
                else empty end),
              ( $platforms[] as $p
                | if ($p | plat_ok | not)
                  then "\($n): invalid platform '\($p)' (expected os/arch[/variant])"
                  else empty end ) ),

          (if ($img.signature.verify // false)
            then (if (($img.signature.key // "") == "") and (($img.signature.keyless // null) == null)
                  then "\($n): signature.verify requires signature.key or signature.keyless"
                  else empty end)
            else empty end)
        ) ),

    # --- duplicate image names within this file ---------------------------
    ( [ $images[]?.name ] | group_by(.)[] | select(length > 1)
      | "duplicate image name '\(.[0])' in \($file)" ),

    # --- duplicate versions within one image ------------------------------
    ( $images[] as $img
      | [ $img.versions[]?.tag ] | group_by(.)[] | select(length > 1)
      | "\($img.name): tag '\(.[0])' is listed more than once" )
  ]
| .[] | msg
