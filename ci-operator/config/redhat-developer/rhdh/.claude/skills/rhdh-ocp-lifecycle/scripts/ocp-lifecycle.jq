# Shared jq filter for classifying OCP lifecycle versions.
# Reads the raw API response (.data[0].versions) and outputs an array of
# {version, ocp_supported, phase, ga_date, end_of_support_date} objects,
# sorted by version.
#
# Supports OCP 4.x and future 5.x+ versions. Filters out non-X.Y names
# (e.g., "3", "4.6 EUS") and versions older than 4.1.
#
# Requires --arg today "YYYY-MM-DD" to be passed to jq.
#
# This filter is the single source of truth for OCP phase classification.
# It is used by:
#   - rhdh-ocp-lifecycle/scripts/check-ocp-lifecycle.sh (same skill)
#   - rhdh-ocp-coverage/scripts/analyze-coverage.sh (sibling skill)
# If this file is moved or renamed, update both consumers.
#
# Usage:
#   jq --arg today "$(date -u +%Y-%m-%d)" -f ocp-lifecycle.jq <<< "$API_RESPONSE"

def is_date: . and . != "N/A" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}") // false);
def to_date: if is_date then split("T")[0] else null end;

.data[0].versions
# Keep only clean X.Y version names, skip variants like "4.6 EUS" or bare "3"
| map(select(.name | test("^[0-9]+\\.[0-9]+$")))
# Filter to OCP 4.x and above (future-proof for 5.x+)
| map(select(.name | split(".") | map(tonumber) | .[0] >= 4))
| map(
  . as $ver |
  ["Extended update support Term 2", "Extended update support", "Maintenance support", "Full support"] as $phase_order |

  # Find latest end-of-support date across all support phases
  ([$ver.phases[] | select(.name == ($phase_order[])) | .end_date | select(is_date) | to_date] | sort | last // null) as $end_of_support |

  # GA date
  ($ver.phases | map(select(.name == "General availability")) | first // {} | .end_date // "N/A") as $ga_raw |

  # Determine current phase (date-only comparison so the final day is fully inclusive)
  (
    $phase_order | map(. as $pname |
      $ver.phases[] | select(.name == $pname) |
      (.start_date | to_date) as $start |
      (.end_date) as $end_raw |
      (.end_date | to_date) as $end |
      if $start and ($start <= $today) then
        if $end and ($end >= $today) then $pname
        elif ($end_raw | is_date | not) and $end_raw != "N/A" and $end_raw != "" and $end_raw != null then $pname
        else empty end
      else empty end
    ) | first // "End of life"
  ) as $current_phase |

  {
    version: $ver.name,
    ocp_supported: ($current_phase != "End of life"),
    phase: $current_phase,
    ga_date: (if ($ga_raw | is_date) then $ga_raw | split("T")[0] else "N/A" end),
    end_of_support_date: (if $end_of_support then $end_of_support else "N/A" end)
  }
)
| sort_by(.version | split(".") | map(tonumber))
