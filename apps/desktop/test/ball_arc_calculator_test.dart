import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/ball/ball_arc_calculator.dart';

void main() {
  const config = BallArcConfig.standard;
  const window = Size(520, 640);
  // Safe inner bounds used by the calculator for a 390x360 menu stage.
  final innerLeft = config.screenMargin + config.buttonRadius + 2.0;
  final innerRight = window.width - innerLeft;
  final innerTop = config.screenMargin + config.buttonRadius + config.labelHeight;
  final innerBottom = window.height - innerTop;

  void expectInside(Offset p) {
    expect(p.dx, greaterThanOrEqualTo(innerLeft - 0.001));
    expect(p.dx, lessThanOrEqualTo(innerRight + 0.001));
    expect(p.dy, greaterThanOrEqualTo(innerTop - 0.001));
    expect(p.dy, lessThanOrEqualTo(innerBottom + 0.001));
  }

  BallArcResult layout(Offset center, BallDockEdge edge) =>
      BallArcCalculator.calculate(
        ballCenter: center,
        edge: edge,
        windowSize: window,
        itemCount: 6,
        config: config,
      );

  test('arc opens toward the interior for every docked edge', () {
    final cases = <(BallDockEdge, double)>[
      (BallDockEdge.left, 0.0),
      (BallDockEdge.right, math.pi),
      (BallDockEdge.top, math.pi / 2),
      (BallDockEdge.bottom, 3 * math.pi / 2),
    ];
    final center = Offset(window.width / 2, window.height / 2);
    for (final (edge, expected) in cases) {
      final result = layout(center, edge);
      expect(
        result.centerAngle,
        closeTo(expected, 0.02),
        reason: 'center angle for $edge',
      );
      for (final p in result.positions) {
        expectInside(p);
      }
    }
  });

  test('buttons are evenly spaced and inside the window near each corner', () {
    final corners = <Offset>[
      Offset(innerLeft, innerTop),
      Offset(innerRight, innerTop),
      Offset(innerLeft, innerBottom),
      Offset(innerRight, innerBottom),
      const Offset(260, 320),
    ];
    for (final edge in BallDockEdge.values) {
      for (final corner in corners) {
        final result = layout(corner, edge);
        expect(result.positions, hasLength(6));
        // Angular step between consecutive buttons is constant.
        final steps = <double>[];
        for (var i = 1; i < result.positions.length; i++) {
          final a = math.atan2(
            result.positions[i].dy - corner.dy,
            result.positions[i].dx - corner.dx,
          );
          final b = math.atan2(
            result.positions[i - 1].dy - corner.dy,
            result.positions[i - 1].dx - corner.dx,
          );
          var step = (a - b) % (2 * math.pi);
          if (step < 0) step += 2 * math.pi;
          if (step > math.pi) step = 2 * math.pi - step;
          steps.add(step);
        }
        for (final step in steps) {
          expect(step, closeTo(steps.first, 0.001));
        }
        for (final p in result.positions) {
          expectInside(p);
        }
      }
    }
  });

  test('corner layouts shrink the arc rather than clipping buttons', () {
    // Ball jammed into the top-right corner: the right/top edges leave no
    // room outward, so the fan must re-center toward the interior diagonal.
    final result = layout(Offset(innerRight, innerTop), BallDockEdge.right);
    for (final p in result.positions) {
      expectInside(p);
    }
    // The used fan cannot point straight at the blocked screen edge.
    expect(result.startAngle, lessThan(result.centerAngle));
    expect(result.endAngle, greaterThan(result.centerAngle));
  });

  test('nearestEdge picks the closest of all four edges', () {
    expect(
      BallArcCalculator.nearestEdge(const Offset(10, 320), window),
      BallDockEdge.left,
    );
    expect(
      BallArcCalculator.nearestEdge(const Offset(510, 320), window),
      BallDockEdge.right,
    );
    expect(
      BallArcCalculator.nearestEdge(const Offset(260, 10), window),
      BallDockEdge.top,
    );
    expect(
      BallArcCalculator.nearestEdge(const Offset(260, 630), window),
      BallDockEdge.bottom,
    );
  });

  test('snapToEdge keeps the ball fully inside the window', () {
    const radius = 36.0;
    final cases = <(Offset, BallDockEdge, Offset)>[
      (const Offset(10, 300), BallDockEdge.left, const Offset(radius, 300)),
      (
        const Offset(510, 300),
        BallDockEdge.right,
        Offset(window.width - radius, 300),
      ),
      (const Offset(300, 10), BallDockEdge.top, const Offset(300, radius)),
      (
        const Offset(300, 630),
        BallDockEdge.bottom,
        Offset(300, window.height - radius),
      ),
    ];
    for (final (center, edge, expected) in cases) {
      final snapped = BallArcCalculator.snapToEdge(
        center,
        edge,
        window,
        ballRadius: radius,
      );
      expect(snapped.dx, closeTo(expected.dx, 0.001));
      expect(snapped.dy, closeTo(expected.dy, 0.001));
    }
  });
}
