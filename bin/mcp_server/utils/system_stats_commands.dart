/// Parsed system stats command with validation support
class ParsedSystemStatsCommand {
  final String operation;
  final Map<String, String> options;
  final String rawInput;

  ParsedSystemStatsCommand({
    required this.operation,
    this.options = const {},
    required this.rawInput,
  });

  @override
  String toString() {
    return 'ParsedSystemStatsCommand(operation: $operation, options: $options)';
  }
}

/// Result of system stats command validation
class SystemStatsValidationResult {
  final bool isAllowed;
  final String? reason;
  final ParsedSystemStatsCommand? parsedCommand;

  SystemStatsValidationResult.allowed(this.parsedCommand)
      : isAllowed = true,
        reason = null;

  SystemStatsValidationResult.denied(this.reason)
      : isAllowed = false,
        parsedCommand = null;

  @override
  String toString() {
    if (isAllowed) {
      return 'SystemStatsValidationResult(allowed: $parsedCommand)';
    }
    return 'SystemStatsValidationResult(denied: $reason)';
  }
}

/// Parser and validator for system stats operations
/// All operations are read-only by design
class SystemStatsCommandParser {
  /// Allowed operations
  static const Set<String> allowedOperations = {
    'all',
    'health',
    'disk-io',
    'memory',
    'network',
    'disk-usage',
    'processes',
  };

  /// Validates the operation
  static SystemStatsValidationResult validate(String operation) {
    final trimmed = operation.trim().toLowerCase();
    
    if (trimmed.isEmpty) {
      return SystemStatsValidationResult.denied('No operation specified');
    }

    // Check for shell injection attempts
    if (_containsDangerousCharacters(trimmed)) {
      return SystemStatsValidationResult.denied(
        'Invalid characters in operation',
      );
    }

    if (!allowedOperations.contains(trimmed)) {
      return SystemStatsValidationResult.denied(
        'Unknown operation "$trimmed". Allowed: ${allowedOperations.join(", ")}',
      );
    }

    return SystemStatsValidationResult.allowed(
      ParsedSystemStatsCommand(
        operation: trimmed,
        rawInput: operation,
      ),
    );
  }

  /// Check for any dangerous characters
  static bool _containsDangerousCharacters(String input) {
    // Only allow alphanumeric and dash
    final validPattern = RegExp(r'^[a-z0-9\-]+$');
    return !validPattern.hasMatch(input);
  }

  /// Convenience method
  static bool isAllowed(String operation) {
    return validate(operation).isAllowed;
  }
}

/// Commands to gather system statistics
/// These are hardcoded for security - no user input in commands
class SystemStatsCommands {
  /// Health overview: load, CPU, memory summary, swap, pressure, uptime
  static const String health = r'''
echo "=== HEALTH ==="
echo -n "load: "; cat /proc/loadavg | awk '{print $1, $2, $3}'
echo -n "uptime: "; uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*//'
echo "cpu: $(awk '/^cpu / {u=$2+$4; t=$2+$4+$5; if(NR==1){u1=u;t1=t} else {printf "usr=%.0f%% sys=%.0f%% idle=%.0f%%", ($2-u1)/(t-t1)*100, ($4-u1)/(t-t1)*100, ($5-0)/(t-t1)*100}}' /proc/stat /proc/stat 2>/dev/null || echo "N/A")"
free -b | awk '/^Mem:/ {printf "mem: total=%.1fG used=%.1fG(%.0f%%) avail=%.1fG\n", $2/1073741824, $3/1073741824, $3/$2*100, $7/1073741824}'
free -b | awk '/^Swap:/ {if($2>0) printf "swap: total=%.1fG used=%.1fG(%.0f%%)\n", $2/1073741824, $3/1073741824, $3/$2*100; else print "swap: none"}'
if [ -f /proc/pressure/cpu ]; then echo -n "pressure: cpu="; awk -F= '/some/ {gsub(/some avg10=/,""); print $2}' /proc/pressure/cpu | cut -d' ' -f1 | tr -d '\n'; echo -n "% mem="; awk -F= '/some/ {gsub(/some avg10=/,""); print $2}' /proc/pressure/memory | cut -d' ' -f1 | tr -d '\n'; echo -n "% io="; awk -F= '/some/ {gsub(/some avg10=/,""); print $2}' /proc/pressure/io | cut -d' ' -f1; fi
''';

  /// Disk I/O statistics
  static const String diskIo = r'''
echo "=== DISK-IO ==="
if command -v iostat >/dev/null 2>&1; then
  iostat -dx 1 2 | awk '
    /^[a-z]/ && !/^Linux/ && !/^Device/ && NR>10 {
      printf "%s: r=%.1fMB/s w=%.1fMB/s util=%.0f%% await=%.1fms qlen=%.1f\n", 
        $1, $3/1024, $4/1024, $NF, $(NF-3), $(NF-2)
    }'
else
  cat /proc/diskstats | awk '$3 ~ /^[a-z]+$/ && $3 !~ /^loop/ {
    printf "%s: reads=%d writes=%d\n", $3, $4, $8
  }'
fi
''';

  /// Memory and swap details with paging statistics
  static const String memory = r'''
echo "=== MEMORY ==="
free -b | awk '
  /^Mem:/ {printf "mem: total=%.2fG used=%.2fG free=%.2fG buffers=%.0fM cached=%.0fM avail=%.2fG\n", 
    $2/1073741824, $3/1073741824, $4/1073741824, $6/1048576, $6/1048576, $7/1073741824}
  /^Swap:/ {if($2>0) printf "swap: total=%.2fG used=%.2fG free=%.2fG\n", 
    $2/1073741824, $3/1073741824, $4/1073741824; else print "swap: disabled"}'
awk '/pgpgin|pgpgout|pswpin|pswpout/ {printf "%s=%s ", $1, $2}' /proc/vmstat | head -1
echo ""
if [ -f /proc/pressure/memory ]; then
  echo -n "pressure: "
  awk '/some/ {print "some="$2} /full/ {print "full="$2}' /proc/pressure/memory | tr '\n' ' '
  echo ""
fi
grep -E "^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback|AnonPages|Mapped|Shmem):" /proc/meminfo | awk '{printf "%s=%s ", $1, $2}' 
echo ""
''';

  /// Network interface statistics
  static const String network = r'''
echo "=== NETWORK ==="
cat /proc/net/dev | awk '
  NR>2 && $1 !~ /lo:/ {
    gsub(/:/, "", $1)
    printf "%s: rx=%.1fMB tx=%.1fMB rx_pkt=%d tx_pkt=%d rx_err=%d tx_err=%d rx_drop=%d tx_drop=%d\n",
      $1, $2/1048576, $10/1048576, $3, $11, $4, $12, $5, $13
  }'
echo -n "connections: "
ss -s 2>/dev/null | awk '
  /^TCP:/ {
    match($0, /estab ([0-9]+)/, e)
    match($0, /timewait ([0-9]+)/, t)
    printf "established=%s timewait=%s ", e[1], t[1]
  }
  /^UDP:/ {
    match($0, /([0-9]+) UDP/, u)
    printf "udp=%s", u[1]
  }' || netstat -an 2>/dev/null | awk '
  /ESTABLISHED/ {e++} /TIME_WAIT/ {t++} /LISTEN/ {l++}
  END {printf "established=%d timewait=%d listen=%d", e, t, l}'
echo ""
if [ -f /proc/pressure/io ]; then
  echo -n "io_pressure: "
  awk '/some/ {print "some="$2} /full/ {print "full="$2}' /proc/pressure/io | tr '\n' ' '
  echo ""
fi
''';

  /// Disk usage by filesystem
  static const String diskUsage = r'''
echo "=== DISK-USAGE ==="
df -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk '
  NR>1 && $1 !~ /^\/dev\/loop/ {
    pct = int($5)
    warn = ""
    if (pct >= 90) warn = " [CRITICAL]"
    else if (pct >= 80) warn = " [WARNING]"
    else if (pct >= 70) warn = " [ATTENTION]"
    printf "%s: %d%% of %.1fG (%.1fG free)%s\n", 
      $6, pct, $2/1073741824, $4/1073741824, warn
  }'
echo "inodes:"
df -i -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk '
  NR>1 && $1 !~ /^\/dev\/loop/ && $2 > 0 {
    pct = int($5)
    if (pct >= 80) printf "  %s: %d%% inodes used [WARNING]\n", $6, pct
  }'
''';

  /// Top processes by resource usage
  static const String processes = r'''
echo "=== PROCESSES ==="
echo "summary: $(ps aux | wc -l) total, $(ps aux | awk '$8=="R" {c++} END {print c+0}') running, $(ps aux | awk '$8~/^Z/ {c++} END {print c+0}') zombie"
echo "by_cpu:"
ps aux --sort=-%cpu | awk 'NR>1 && NR<=6 && $3>0.1 {printf "  %s (pid=%s): %.1f%% cpu, %.1f%% mem\n", $11, $2, $3, $4}'
echo "by_mem:"
ps aux --sort=-%mem | awk 'NR>1 && NR<=6 && $4>0.1 {printf "  %s (pid=%s): %.1f%% mem (%.0fMB rss)\n", $11, $2, $4, $6/1024}'
if command -v pidstat >/dev/null 2>&1; then
  echo "by_io:"
  pidstat -d 1 1 2>/dev/null | awk 'NR>3 && $4+$5>100 {printf "  %s (pid=%s): r=%.0fKB/s w=%.0fKB/s\n", $NF, $3, $4, $5}' | head -5
fi
''';

  /// Get command for operation
  static String? getCommand(String operation) {
    switch (operation) {
      case 'health':
        return health;
      case 'disk-io':
        return diskIo;
      case 'memory':
        return memory;
      case 'network':
        return network;
      case 'disk-usage':
        return diskUsage;
      case 'processes':
        return processes;
      case 'all':
        return [health, diskIo, memory, network, diskUsage, processes].join('\n');
      default:
        return null;
    }
  }

  /// Get list of operations that will be run
  static List<String> getOperationsForCommand(String operation) {
    if (operation == 'all') {
      return ['health', 'disk-io', 'memory', 'network', 'disk-usage', 'processes'];
    }
    return [operation];
  }
}
