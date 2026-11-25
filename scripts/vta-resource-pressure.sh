#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Generate bounded CPU or memory pressure in the VTA identified by its DID.

Usage:
  vta-resource-pressure.sh --did <did> --resource <cpu|memory> \
    --level <warning|critical> [options]

Options:
  --context <name>       Kubernetes context (default: rke2-vtafarm-dev)
  --namespace <name>     Search only this namespace
  --duration <seconds>   Override the rule-aware hold time
  --allow-non-dev        Permit a context whose name does not contain "dev"
  --yes                  Skip the interactive confirmation
  --dry-run              Resolve the VTA and show the planned pressure only
  -h, --help             Show this help

Default targets and durations:
  CPU warning:     82% for 1020s (5m metric window + 10m alert + delivery)
  CPU critical:    95% for 720s  (5m metric window + 5m alert + delivery)
  Memory warning:  82% for 660s  (10m alert + delivery)
  Memory critical: 92% for 360s  (5m alert + delivery; may cause an OOM restart)

The process always exits after the selected duration. Run only one pressure test
at a time so the resulting incident has an unambiguous cause.
EOF
}

CONTEXT="rke2-vtafarm-dev"
NAMESPACE=""
DID=""
RESOURCE=""
LEVEL=""
DURATION=""
ALLOW_NON_DEV=false
ASSUME_YES=false
DRY_RUN=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context)
      [ "$#" -ge 2 ] || fail "--context requires a value"
      CONTEXT="$2"
      shift 2
      ;;
    --namespace)
      [ "$#" -ge 2 ] || fail "--namespace requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    --did)
      [ "$#" -ge 2 ] || fail "--did requires a value"
      DID="$2"
      shift 2
      ;;
    --resource)
      [ "$#" -ge 2 ] || fail "--resource requires a value"
      RESOURCE="$2"
      shift 2
      ;;
    --level)
      [ "$#" -ge 2 ] || fail "--level requires a value"
      LEVEL="$2"
      shift 2
      ;;
    --duration)
      [ "$#" -ge 2 ] || fail "--duration requires a value"
      DURATION="$2"
      shift 2
      ;;
    --allow-non-dev) ALLOW_NON_DEV=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

command -v kubectl >/dev/null || fail "kubectl is required"
command -v awk >/dev/null || fail "awk is required"

[ -n "$DID" ] || fail "--did is required"
[[ "$DID" == did:* ]] || fail "--did must start with did:"
[[ "$DID" != *$'\n'* && "$DID" != *$'\r'* ]] || fail "--did must be one line"
case "$RESOURCE" in cpu|memory) ;; *) fail "--resource must be cpu or memory" ;; esac
case "$LEVEL" in warning|critical) ;; *) fail "--level must be warning or critical" ;; esac
[[ "$CONTEXT" =~ ^[-A-Za-z0-9_.]+$ ]] || fail "invalid Kubernetes context name"
if [ -n "$NAMESPACE" ]; then
  [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || fail "invalid namespace"
fi
if [[ "$CONTEXT" != *dev* ]] && [ "$ALLOW_NON_DEV" != true ]; then
  fail "refusing non-development context '$CONTEXT'; pass --allow-non-dev deliberately"
fi

if [ -z "$DURATION" ]; then
  case "$RESOURCE:$LEVEL" in
    cpu:warning) DURATION=1020 ;;
    cpu:critical) DURATION=720 ;;
    memory:warning) DURATION=660 ;;
    memory:critical) DURATION=360 ;;
  esac
fi
[[ "$DURATION" =~ ^[0-9]+$ ]] || fail "--duration must be an integer number of seconds"
DURATION=$((10#$DURATION))
[ "$DURATION" -ge 30 ] && [ "$DURATION" -le 3600 ] || fail "--duration must be between 30 and 3600 seconds"

if [ "$RESOURCE" = memory ]; then
  if [ "$LEVEL" = warning ]; then TARGET_PERCENT=82; else TARGET_PERCENT=92; fi
else
  if [ "$LEVEL" = warning ]; then TARGET_PERCENT=82; else TARGET_PERCENT=95; fi
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vta-pressure.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

pod_args=(--context "$CONTEXT" get pods --sort-by=.metadata.creationTimestamp)
if [ -n "$NAMESPACE" ]; then pod_args+=(-n "$NAMESPACE"); else pod_args+=(-A); fi
pod_args+=(-l session-id --field-selector=status.phase=Running -o \
  'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.metadata.labels.app}{"\t"}{.spec.containers[0].name}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}')

kubectl "${pod_args[@]}" >"$WORK_DIR/pods" || fail "cannot list VTA pods in context '$CONTEXT'"

MATCH_NAMESPACE=""
MATCH_POD=""
MATCH_CONTAINER=""
while IFS=$'\t' read -r namespace pod app container ready; do
  case "$app" in vta|fs-vta) ;; *) continue ;; esac
  [ "$ready" = true ] || continue
  candidate_did="$(kubectl --context "$CONTEXT" -n "$namespace" exec "$pod" -c "$container" -- \
    awk -F '"' '/^[[:space:]]*vta_did[[:space:]]*=/{print $2; exit}' /work/vta/config.toml \
    2>/dev/null || true)"
  if [ "$candidate_did" = "$DID" ]; then
    # Pods are sorted oldest first, so a rolling update resolves to its newest ready Pod.
    MATCH_NAMESPACE="$namespace"
    MATCH_POD="$pod"
    MATCH_CONTAINER="$container"
  fi
done <"$WORK_DIR/pods"

[ -n "$MATCH_POD" ] || fail "no ready VTA Pod matched the supplied DID"

echo "VTA:       $DID"
echo "Context:   $CONTEXT"
echo "Pod:       $MATCH_NAMESPACE/$MATCH_POD"
echo "Resource:  $RESOURCE"
echo "Level:     $LEVEL"
echo "Target:    ${TARGET_PERCENT}%"
echo "Duration:  ${DURATION}s"

if [ "$RESOURCE" = cpu ]; then
  CPU_LIMIT="$(kubectl --context "$CONTEXT" -n "$MATCH_NAMESPACE" get pod "$MATCH_POD" \
    -o 'jsonpath={.spec.containers[0].resources.limits.cpu}')"
  [ -n "$CPU_LIMIT" ] || fail "the VTA has no CPU limit"
  CPU_LIMIT_M="$(awk -v quantity="$CPU_LIMIT" 'BEGIN {
    if (quantity ~ /m$/) { sub(/m$/, "", quantity); value = quantity }
    else if (quantity ~ /u$/) { sub(/u$/, "", quantity); value = quantity / 1000 }
    else if (quantity ~ /n$/) { sub(/n$/, "", quantity); value = quantity / 1000000 }
    else { value = quantity * 1000 }
    printf "%.0f", value
  }')"
  [[ "$CPU_LIMIT_M" =~ ^[0-9]+$ ]] && [ "$CPU_LIMIT_M" -gt 0 ] || fail "unsupported CPU limit: $CPU_LIMIT"
  DESIRED_CPU_M=$((CPU_LIMIT_M * TARGET_PERCENT / 100))
  [ "$DESIRED_CPU_M" -gt 0 ] || DESIRED_CPU_M=1
  echo "CPU limit: ${CPU_LIMIT_M}m; planned load: approximately ${DESIRED_CPU_M}m"
  kubectl --context "$CONTEXT" -n "$MATCH_NAMESPACE" exec "$MATCH_POD" -c "$MATCH_CONTAINER" -- \
    perl -e 1 >/dev/null 2>&1 || fail "the VTA image needs Perl for bounded CPU pressure"
else
  read -r MEMORY_LIMIT MEMORY_CURRENT MEMORY_INACTIVE_FILE < <(
    kubectl --context "$CONTEXT" -n "$MATCH_NAMESPACE" exec "$MATCH_POD" -c "$MATCH_CONTAINER" -- sh -c '
      if [ -r /sys/fs/cgroup/memory.max ] && [ "$(cat /sys/fs/cgroup/memory.max)" != max ]; then
        limit_path=/sys/fs/cgroup/memory.max
        usage_path=/sys/fs/cgroup/memory.current
        stat_path=/sys/fs/cgroup/memory.stat
        inactive_key=inactive_file
      elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        limit_path=/sys/fs/cgroup/memory/memory.limit_in_bytes
        usage_path=/sys/fs/cgroup/memory/memory.usage_in_bytes
        stat_path=/sys/fs/cgroup/memory/memory.stat
        inactive_key=total_inactive_file
      else
        exit 1
      fi
      inactive_file=0
      while read -r stat_key stat_value _; do
        if [ "$stat_key" = "$inactive_key" ]; then
          inactive_file="$stat_value"
          break
        fi
      done < "$stat_path"
      printf "%s %s %s\n" "$(cat "$limit_path")" "$(cat "$usage_path")" "$inactive_file"'
  )
  [[ "${MEMORY_LIMIT:-}" =~ ^[0-9]+$ && "${MEMORY_CURRENT:-}" =~ ^[0-9]+$ &&
    "${MEMORY_INACTIVE_FILE:-}" =~ ^[0-9]+$ ]] ||
    fail "the VTA has no readable memory cgroup limit"
  if [ "$MEMORY_CURRENT" -gt "$MEMORY_INACTIVE_FILE" ]; then
    MEMORY_WORKING_SET=$((MEMORY_CURRENT - MEMORY_INACTIVE_FILE))
  else
    MEMORY_WORKING_SET=0
  fi
  MEMORY_TARGET=$((MEMORY_LIMIT * TARGET_PERCENT / 100))
  echo "Memory limit: $((MEMORY_LIMIT / 1024 / 1024))MiB; current working set: $((MEMORY_WORKING_SET / 1024 / 1024))MiB"
  echo "Planned working-set target: $((MEMORY_TARGET / 1024 / 1024))MiB"
  kubectl --context "$CONTEXT" -n "$MATCH_NAMESPACE" exec "$MATCH_POD" -c "$MATCH_CONTAINER" -- \
    perl -e 1 >/dev/null 2>&1 || fail "the VTA image needs Perl for bounded memory pressure"
fi

if [ "$DRY_RUN" = true ]; then
  echo "Dry run only; no pressure was generated."
  exit 0
fi

if [ "$ASSUME_YES" != true ]; then
  [ -t 0 ] || fail "interactive confirmation unavailable; pass --yes deliberately"
  read -r -p "Type 'yes' to generate pressure in this VTA: " answer
  [ "$answer" = yes ] || fail "cancelled"
fi

echo "Starting bounded $RESOURCE pressure. Keep this terminal open; Ctrl-C stops kubectl, and the remote load has a finite duration."
if [ "$RESOURCE" = cpu ]; then
  kubectl --context "$CONTEXT" -n "$MATCH_NAMESPACE" exec "$MATCH_POD" -c "$MATCH_CONTAINER" -- \
    perl -e '
      use strict;
      use warnings;
      my ($millicores, $seconds) = @ARGV;
      sub now {
        open my $fh, "<", "/proc/uptime" or die "cannot read /proc/uptime: $!\n";
        my $line = <$fh>;
        close $fh;
        return (split /\s+/, $line)[0];
      }
      my $end = now() + $seconds;
      my @children;
      sub burn {
        my ($duty) = @_;
        $SIG{INT} = $SIG{TERM} = sub { exit 0 };
        while (now() < $end) {
          my $start = now();
          my $cycle_end = $start + 0.1;
          $cycle_end = $end if $cycle_end > $end;
          my $busy_end = $duty >= 0.999 ? $cycle_end : $start + (0.1 * $duty);
          $busy_end = $cycle_end if $busy_end > $cycle_end;
          my $value = 0;
          $value++ while now() < $busy_end;
          my $remaining = $cycle_end - now();
          select undef, undef, undef, $remaining if $remaining > 0;
        }
        exit 0;
      }
      my $full = int($millicores / 1000);
      my $partial = ($millicores % 1000) / 1000;
      for (1 .. $full) {
        my $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) { burn(1) }
        push @children, $pid;
      }
      if ($partial > 0) {
        my $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) { burn($partial) }
        push @children, $pid;
      }
      $SIG{INT} = $SIG{TERM} = sub { kill "TERM", @children; };
      waitpid($_, 0) for @children;
    ' "$DESIRED_CPU_M" "$DURATION"
else
  kubectl --context "$CONTEXT" -n "$MATCH_NAMESPACE" exec "$MATCH_POD" -c "$MATCH_CONTAINER" -- \
    perl -e '
      use strict;
      use warnings;
      my ($target, $seconds) = @ARGV;
      my @chunks;
      sub read_number {
        my ($path) = @_;
        open my $fh, "<", $path or die "cannot read $path: $!\n";
        my $value = <$fh>;
        close $fh;
        chomp $value;
        die "invalid value in $path\n" unless $value =~ /^\d+$/;
        return $value;
      }
      sub working_set {
        my ($usage_path, $stat_path, $inactive_key);
        if (-r "/sys/fs/cgroup/memory.current") {
          ($usage_path, $stat_path, $inactive_key) = (
            "/sys/fs/cgroup/memory.current", "/sys/fs/cgroup/memory.stat", "inactive_file"
          );
        } elsif (-r "/sys/fs/cgroup/memory/memory.usage_in_bytes") {
          ($usage_path, $stat_path, $inactive_key) = (
            "/sys/fs/cgroup/memory/memory.usage_in_bytes",
            "/sys/fs/cgroup/memory/memory.stat",
            "total_inactive_file"
          );
        } else {
          die "cannot read cgroup memory usage\n";
        }
        my $usage = read_number($usage_path);
        my $inactive = 0;
        open my $fh, "<", $stat_path or die "cannot read $stat_path: $!\n";
        while (my $line = <$fh>) {
          my ($key, $value) = split /\s+/, $line;
          if ($key eq $inactive_key && defined $value && $value =~ /^\d+$/) {
            $inactive = $value;
            last;
          }
        }
        close $fh;
        return $usage > $inactive ? $usage - $inactive : 0;
      }
      sub now {
        open my $fh, "<", "/proc/uptime" or die "cannot read /proc/uptime: $!\n";
        my $line = <$fh>;
        close $fh;
        return (split /\s+/, $line)[0];
      }
      while (1) {
        my $current = working_set();
        last if $current >= $target;
        my $chunk = $target - $current;
        $chunk = 262144 if $chunk > 262144;
        push @chunks, "x" x $chunk;
        select undef, undef, undef, 0.02;
      }
      my $end = now() + $seconds;
      while (now() < $end) {
        my $current = working_set();
        if ($current < $target) {
          my $chunk = $target - $current;
          $chunk = 262144 if $chunk > 262144;
          push @chunks, "x" x $chunk;
        } else {
          my $remaining = $end - now();
          my $pause = $remaining < 0.1 ? $remaining : 0.1;
          select undef, undef, undef, $pause if $pause > 0;
        }
      }
    ' "$MEMORY_TARGET" "$DURATION"
fi

echo "Pressure test finished. The incident can take another scrape/evaluation cycle to appear or resolve."
