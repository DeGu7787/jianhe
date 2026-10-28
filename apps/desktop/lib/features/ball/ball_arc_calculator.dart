import 'dart:math' as math;
import 'dart:ui';

/// The four screen edges a floating ball can dock to.
enum BallDockEdge { left, right, top, bottom }

/// Tunable parameters for the floating ball and its arc menu.
///
/// Every layout quantity is derived from a single shared configuration so the
/// same geometry is used by the Flutter-rendered menu, hit regions and tests.
class BallArcConfig {
  const BallArcConfig({
    this.ballDiameter = 72.0,
    this.buttonDiameter = 44.0,
    this.labelHeight = 22.0,
    this.expandRadius = 130.0,
    this.totalAngleRange = 5 * math.pi / 6,
    this.minAnglePerItem = 0.38,
    this.itemSpacing = 54.0,
    this.screenMargin = 16.0,
    this.snapThreshold = 100.0,
    this.dragThreshold = 8.0,
    this.expandDurationMs = 260,
    this.collapseDurationMs = 220,
    this.itemStaggerMs = 42,
    this.snapDurationMs = 200,
    this.maxRadiusFactor = 1.45,
  });

  /// Diameter of the floating ball in logical pixels.
  final double ballDiameter;

  /// Diameter of each arc menu button in logical pixels.
  final double buttonDiameter;

  /// Height of the caption rendered below each button. It participates in the
  /// screen-boundary check so labels never get clipped at the window edge.
  final double labelHeight;

  /// Default distance from the ball center to the menu button centers.
  final double expandRadius;

  /// Preferred angular span of the whole arc (radians). The layout clamps or
  /// reduces this automatically near screen corners.
  final double totalAngleRange;

  /// Minimum angular step (radians) between adjacent buttons.
  final double minAnglePerItem;

  /// Preferred linear distance between adjacent button centers (logical px).
  /// When non-zero the angular step is at least `itemSpacing / radius`.
  final double itemSpacing;

  /// Safe distance kept between any menu element and the window edge.
  final double screenMargin;

  /// Distance beyond which a released ball snaps to the nearest edge.
  final double snapThreshold;

  /// Movement distance (logical px) that distinguishes a drag from a click.
  final double dragThreshold;

  /// Menu expand animation duration in milliseconds.
  final int expandDurationMs;

  /// Menu collapse animation duration in milliseconds.
  final int collapseDurationMs;

  /// Per-button stagger added on top of the base duration.
  final int itemStaggerMs;

  /// Snap-to-edge animation duration in milliseconds.
  final int snapDurationMs;

  /// Upper bound for the radius used near corners: `expandRadius * maxRadiusFactor`.
  final double maxRadiusFactor;

  double get ballRadius => ballDiameter / 2;
  double get buttonRadius => buttonDiameter / 2;

  static const BallArcConfig standard = BallArcConfig();
}

/// Result of a single arc layout pass.
class BallArcResult {
  const BallArcResult({
    required this.positions,
    required this.startAngle,
    required this.endAngle,
    required this.usedRadius,
    required this.centerAngle,
    required this.isCornerClamped,
  });

  /// Center points of the menu buttons (window coordinates).
  final List<Offset> positions;

  final double startAngle;
  final double endAngle;

  /// Radius that was actually used (may differ from [BallArcConfig.expandRadius]
  /// when the ball sits near a screen corner).
  final double usedRadius;

  final double centerAngle;

  /// True when the arc had to be shrunk / re-centered because of screen bounds.
  final bool isCornerClamped;
}

class BallArcCalculator {
  const BallArcCalculator._();

  static double _centerAngleForEdge(BallDockEdge edge) => switch (edge) {
    BallDockEdge.left => 0.0,
    BallDockEdge.right => math.pi,
    BallDockEdge.top => math.pi / 2,
    BallDockEdge.bottom => 3 * math.pi / 2,
  };

  /// Computes the arc layout for [itemCount] buttons around [ballCenter].
  ///
  /// A single unified calculation is used for every docked edge:
  /// 1. the base direction comes from [_centerAngleForEdge] (the arc always
  ///    opens toward the screen interior);
  /// 2. the largest contiguous angle window that keeps every button inside
  ///    [windowSize] is intersected with that direction;
  /// 3. near a corner the center angle shifts toward the interior diagonal and
  ///    the radius may be enlarged (up to `expandRadius * maxRadiusFactor`) so
  ///    button spacing stays uniform;
  /// 4. button positions are derived with plain trigonometry and always remain
  ///    evenly spaced.
  static BallArcResult calculate({
    required Offset ballCenter,
    required BallDockEdge edge,
    required Size windowSize,
    required int itemCount,
    BallArcConfig config = BallArcConfig.standard,
  }) {
    if (itemCount <= 0) {
      return BallArcResult(
        positions: const [],
        startAngle: 0,
        endAngle: 0,
        usedRadius: config.expandRadius,
        centerAngle: _centerAngleForEdge(edge),
        isCornerClamped: false,
      );
    }

    final centerAngle = _centerAngleForEdge(edge);
    final horizontalInset = config.buttonRadius + 2.0;
    final verticalInset = config.buttonRadius + config.labelHeight;
    final left = config.screenMargin + horizontalInset;
    final right = windowSize.width - config.screenMargin - horizontalInset;
    final top = config.screenMargin + verticalInset;
    final bottom = windowSize.height - config.screenMargin - verticalInset;

    // Angular step respects both a minimum angle and a preferred linear
    // spacing between button centers.
    double stepFor(double radius) {
      final byDistance =
          config.itemSpacing > 0 ? config.itemSpacing / radius : 0.0;
      return math.max(config.minAnglePerItem, byDistance);
    }

    final neededSpan = stepFor(config.expandRadius) * (itemCount - 1);

    // --- pick radius -------------------------------------------------------
    // At the base radius the available angle window can be smaller than what
    // the buttons need (typical near corners). Enlarging the radius widens the
    // window for constraints whose ball offset is already inside the screen, so
    // try increasingly large radii before accepting a tighter fan.
    final maxRadius =
        math.max(config.expandRadius, config.expandRadius * config.maxRadiusFactor);
    var radius = config.expandRadius;
    var window = _safeWindowFor(
      ballCenter: ballCenter,
      radius: radius,
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      centerAngle: centerAngle,
    );
    if (window < neededSpan) {
      var bestRadius = radius;
      var bestWindow = window;
      for (var r = radius + 8.0; r <= maxRadius; r += 8.0) {
        final candidate = _safeWindowFor(
          ballCenter: ballCenter,
          radius: r,
          left: left,
          right: right,
          top: top,
          bottom: bottom,
          centerAngle: centerAngle,
        );
        if (candidate >= neededSpan) {
          bestRadius = r;
          bestWindow = candidate;
          break;
        }
        if (candidate > bestWindow) {
          bestWindow = candidate;
          bestRadius = r;
        }
      }
      radius = bestRadius;
      window = bestWindow;
    }

    // --- pick center angle + half range ------------------------------------
    final desiredHalf = math.max(config.totalAngleRange / 2, neededSpan / 2);
    final halfRange = math.min(desiredHalf, window / 2);
    final isCornerClamped = halfRange < desiredHalf - 0.01;

    final usedCenter = _safeCenterAngle(
      ballCenter: ballCenter,
      radius: radius,
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      centerAngle: centerAngle,
    );

    final startAngle = usedCenter - halfRange;
    final endAngle = usedCenter + halfRange;

    // --- positions ---------------------------------------------------------
    final positions = <Offset>[];
    for (var i = 0; i < itemCount; i++) {
      final fraction = itemCount == 1 ? 0.5 : i / (itemCount - 1);
      final angle = startAngle + fraction * (endAngle - startAngle);
      positions.add(Offset(
        ballCenter.dx + radius * math.cos(angle),
        ballCenter.dy + radius * math.sin(angle),
      ));
    }

    return BallArcResult(
      positions: positions,
      startAngle: startAngle,
      endAngle: endAngle,
      usedRadius: radius,
      centerAngle: usedCenter,
      isCornerClamped: isCornerClamped,
    );
  }

  /// Width (radians) of the largest contiguous angle window that keeps every
  /// button inside the window. When the base direction itself is safe the
  /// window is measured from that direction; otherwise the widest safe piece is
  /// used so the arc can still point toward the screen interior.
  static double _safeWindowFor({
    required Offset ballCenter,
    required double radius,
    required double left,
    required double right,
    required double top,
    required double bottom,
    required double centerAngle,
  }) {
    final pieces = _safeAnglePieces(
      ballCenter: ballCenter,
      radius: radius,
      left: left,
      right: right,
      top: top,
      bottom: bottom,
    );
    if (pieces.isEmpty) return 0;
    final window = _directedWindow(pieces, centerAngle);
    if (window > 1e-6) return window;
    return _widestPiece(pieces)[1] - _widestPiece(pieces)[0];
  }

  /// Center angle used for the actual arc. When the base direction is blocked
  /// by a screen edge (corner), shift to the middle of the available window so
  /// the fan points along the interior diagonal.
  static double _safeCenterAngle({
    required Offset ballCenter,
    required double radius,
    required double left,
    required double right,
    required double top,
    required double bottom,
    required double centerAngle,
  }) {
    final pieces = _safeAnglePieces(
      ballCenter: ballCenter,
      radius: radius,
      left: left,
      right: right,
      top: top,
      bottom: bottom,
    );
    if (pieces.isEmpty) return centerAngle;
    if (_directedWindow(pieces, centerAngle) > 1e-6) {
      return _normalizeAngle(centerAngle);
    }
    final widest = _widestPiece(pieces);
    return (widest[0] + widest[1]) / 2;
  }

  /// Width (radians) of the largest contiguous safe window centered on
  /// [direction], taking the 0/2蟺 seam into account. Returns 0 when the
  /// direction is unsafe or sits exactly on a safe-piece boundary (blocked
  /// corner) so callers re-center on the widest piece instead.
  static double _directedWindow(List<List<double>> pieces, double direction) {
    final d = _normalizeAngle(direction);
    for (final piece in pieces) {
      if (d < piece[0] || d > piece[1]) continue;
      if (piece[1] - piece[0] >= 2 * math.pi - 1e-9) return 2 * math.pi;
      var left = d - piece[0];
      var right = piece[1] - d;
      // Join the wrap-around half of a piece that crosses the 0/2蟺 seam.
      if (piece[0] == 0 && pieces.length > 1 && pieces.last[1] == 2 * math.pi) {
        left += pieces.last[1] - pieces.last[0];
      }
      if (piece[1] == 2 * math.pi && pieces.length > 1 &&
          pieces.first[0] == 0) {
        right += pieces.first[1] - pieces.first[0];
      }
      final window = math.min(left, right) * 2;
      if (window > 1e-6) return window;
      break;
    }
    return 0;
  }

  static List<double> _widestPiece(List<List<double>> pieces) {
    var widest = pieces.first;
    for (final piece in pieces) {
      if (piece[1] - piece[0] > widest[1] - widest[0]) widest = piece;
    }
    return widest;
  }

  /// Intersection of the per-edge angle constraints. Every piece is an
  /// interval [lo, hi] within [0, 2π).
  static List<List<double>> _safeAnglePieces({
    required Offset ballCenter,
    required double radius,
    required double left,
    required double right,
    required double top,
    required double bottom,
  }) {
    final bounds = <List<List<double>>>[
      _leftBoundPieces(ballCenter.dx, radius, left),
      _rightBoundPieces(ballCenter.dx, radius, right),
      _topBoundPieces(ballCenter.dy, radius, top),
      _bottomBoundPieces(ballCenter.dy, radius, bottom),
    ];

    var result = <List<double>>[<double>[0, 2 * math.pi]];
    for (final bound in bounds) {
      if (bound.isEmpty) return const [];
      final next = <List<double>>[];
      for (final segment in result) {
        for (final piece in bound) {
          final lo = math.max(segment[0], piece[0]);
          final hi = math.min(segment[1], piece[1]);
          if (lo < hi) next.add(<double>[lo, hi]);
        }
      }
      result = next;
      if (result.isEmpty) return const [];
    }
    return result;
  }

  /// cos(θ) ≥ (left - cx) / radius  ->  θ ∈ [-acos(k), acos(k)].
  static List<List<double>> _leftBoundPieces(
    double cx,
    double radius,
    double leftLimit,
  ) {
    final k = (leftLimit - cx) / radius;
    if (k <= -1) return <List<double>>[<double>[0, 2 * math.pi]];
    if (k >= 1) return const [];
    final a = math.acos(k);
    return <List<double>>[
      <double>[0, a],
      <double>[2 * math.pi - a, 2 * math.pi],
    ];
  }

  /// cos(θ) ≤ (right - cx) / radius  ->  θ ∈ [acos(k), 2π - acos(k)].
  static List<List<double>> _rightBoundPieces(
    double cx,
    double radius,
    double rightLimit,
  ) {
    final k = (rightLimit - cx) / radius;
    if (k >= 1) return <List<double>>[<double>[0, 2 * math.pi]];
    if (k <= -1) return const [];
    final a = math.acos(k);
    return <List<double>>[<double>[a, 2 * math.pi - a]];
  }

  /// sin(θ) ≥ (top - cy) / radius  ->  θ ∈ [asin(k), π - asin(k)].
  static List<List<double>> _topBoundPieces(
    double cy,
    double radius,
    double topLimit,
  ) {
    final k = (topLimit - cy) / radius;
    if (k <= -1) return <List<double>>[<double>[0, 2 * math.pi]];
    if (k >= 1) return const [];
    final a = math.asin(k);
    return <List<double>>[<double>[a, math.pi - a]];
  }

  /// sin(θ) ≤ (bottom - cy) / radius  ->  θ ∈ [π - asin(k), 2π + asin(k)].
  static List<List<double>> _bottomBoundPieces(
    double cy,
    double radius,
    double bottomLimit,
  ) {
    final k = (bottomLimit - cy) / radius;
    if (k >= 1) return <List<double>>[<double>[0, 2 * math.pi]];
    if (k <= -1) return const [];
    final a = math.asin(k);
    final lo = math.pi - a;
    final hi = 2 * math.pi + a;
    if (hi <= 2 * math.pi) {
      return <List<double>>[<double>[lo, hi]];
    }
    return <List<double>>[
      <double>[lo, 2 * math.pi],
      <double>[0, hi - 2 * math.pi],
    ];
  }

  static double _normalizeAngle(double angle) {
    var result = angle % (2 * math.pi);
    if (result < 0) result += 2 * math.pi;
    return result;
  }

  /// Finds the nearest edge for [center] within [windowSize]. The returned edge
  /// is the one whose perpendicular distance is smallest.
  static BallDockEdge nearestEdge(
    Offset center,
    Size windowSize, {
    double snapThreshold = 100,
  }) {
    var best = BallDockEdge.left;
    var bestDistance = double.infinity;
    void consider(double distance, BallDockEdge edge) {
      if (distance < bestDistance) {
        bestDistance = distance;
        best = edge;
      }
    }

    consider(center.dx, BallDockEdge.left);
    consider(windowSize.width - center.dx, BallDockEdge.right);
    consider(center.dy, BallDockEdge.top);
    consider(windowSize.height - center.dy, BallDockEdge.bottom);
    return best;
  }

  /// Snaps [center] flush to [edge] inside [windowSize]. The returned center
  /// keeps the ball fully inside the window (no clipping).
  static Offset snapToEdge(
    Offset center,
    BallDockEdge edge,
    Size windowSize, {
    double ballRadius = 36,
  }) {
    final r = ballRadius;
    return switch (edge) {
      BallDockEdge.left => Offset(r, center.dy.clamp(r, windowSize.height - r)),
      BallDockEdge.right =>
        Offset(windowSize.width - r, center.dy.clamp(r, windowSize.height - r)),
      BallDockEdge.top =>
        Offset(center.dx.clamp(r, windowSize.width - r), r),
      BallDockEdge.bottom =>
        Offset(center.dx.clamp(r, windowSize.width - r), windowSize.height - r),
    };
  }
}
