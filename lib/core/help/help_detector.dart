import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../shared/widgets/two_tone_icon.dart';
import 'help_target.dart';

/// Hit-test tag marking a subtree as off-limits for the Information Clicker
/// (see `ClickerQuiet`).
const String kClickerQuietTag = 'fyona.clicker.quiet.v1';

/// Why a press produced no help target.
enum HelpQuietReason {
  none,

  /// Inside a `ClickerQuiet` zone (rows/bubbles with their own long press).
  quietZone,

  /// On a text field: long press there belongs to text selection.
  editable,

  /// The pressed element (or a parent) has its own long-press action.
  nativeLongPress,

  /// Background / empty area / decorative content: nothing interactive.
  noTarget,
}

/// What the Information Clicker found under the finger.
class HelpProbe {
  /// Render box of the element (kept to follow it live while scrolling).
  final RenderBox box;

  /// Exact on-screen bounds of the element, in global coordinates.
  final Rect rect;

  /// Id from an enclosing `HelpTarget`, if any.
  final String? explicitId;

  /// Visible texts inside the element, in reading/paint order.
  final List<String> texts;

  /// Tooltip / semantic labels attached to the element.
  final List<String> tooltips;

  /// IconData / HugeIcons lists / TwoToneIconData shown by the element.
  final List<Object> icons;

  /// A tooltip wraps the element (its own long press only shows a bubble,
  /// so the clicker may keep counting after the tooltip wins the arena).
  final bool hasTooltip;

  /// The element is wide like a list row / record card.
  final bool wide;

  /// Global origin of [box] when probed (to follow it if it scrolls).
  final Offset boxOrigin;

  const HelpProbe({
    required this.box,
    required this.boxOrigin,
    required this.rect,
    required this.explicitId,
    required this.texts,
    required this.tooltips,
    required this.icons,
    required this.hasTooltip,
    required this.wide,
  });

  /// Current bounds (follows the element if it scrolls); falls back to
  /// [rect].
  Rect liveRect() {
    try {
      if (box.attached && box.hasSize) {
        final o = box.localToGlobal(Offset.zero);
        return rect.shift(o - boxOrigin);
      }
    } catch (_) {}
    return rect;
  }
}

/// Finds the exact element under a press.
///
/// The target is the INNERMOST interactive render object on the hit path:
/// a tap/long-press gesture handler or a semantics node that is a button,
/// a toggle, a checkbox or has a tap action — i.e. what Flutter itself
/// treats as "something you can press". Inner targets always win over the
/// cards/rows around them; nested buttons are never mixed into their
/// parent's label.
class HelpDetector {
  HelpDetector._();

  static bool isInteractive(RenderObject o) {
    if (o is RenderSemanticsGestureHandler) {
      return o.onTap != null || o.onLongPress != null;
    }
    if (o is RenderSemanticsAnnotations) {
      final p = o.properties;
      return p.onTap != null ||
          p.button == true ||
          p.toggled != null ||
          p.checked != null ||
          p.link == true;
    }
    return false;
  }

  static bool hasLongPress(RenderObject o) {
    if (o is RenderSemanticsGestureHandler) return o.onLongPress != null;
    if (o is RenderSemanticsAnnotations) return o.properties.onLongPress != null;
    return false;
  }

  /// Hit-tests [position] in view [viewId] and probes it.
  static ({HelpProbe? probe, HelpQuietReason reason}) probeAt(
    Offset position, {
    required int viewId,
    required Size screen,
  }) {
    final result = HitTestResult();
    try {
      WidgetsBinding.instance.hitTestInView(result, position, viewId);
    } catch (_) {
      return (probe: null, reason: HelpQuietReason.noTarget);
    }
    return probe(result, position, screen: screen);
  }

  static bool _tooBig(Rect r, Size screen) {
    final area = screen.width * screen.height;
    if (area <= 0) return false;
    if (r.width * r.height > area * 0.5) return true;
    if (r.width > screen.width * 0.96 && r.height > screen.height * 0.6) {
      return true;
    }
    return false;
  }

  static Rect? _globalRect(RenderBox b) {
    if (!b.attached || !b.hasSize) return null;
    try {
      final o = b.localToGlobal(Offset.zero);
      final r = o & b.size;
      if (r.width <= 0 || r.height <= 0) return null;
      return r;
    } catch (_) {
      return null;
    }
  }

  static ({HelpProbe? probe, HelpQuietReason reason}) probe(
    HitTestResult result,
    Offset position, {
    required Size screen,
  }) {
    final path = [for (final e in result.path) e.target];
    // 1. Quiet zones and text fields: never.
    for (final t in path) {
      if (t is RenderMetaData && t.metaData == kClickerQuietTag) {
        return (probe: null, reason: HelpQuietReason.quietZone);
      }
      if (t is RenderEditable) {
        return (probe: null, reason: HelpQuietReason.editable);
      }
    }
    // 2. A native long press anywhere on the path wins the gesture arena
    //    first — the clicker must not compete with it.
    for (final t in path) {
      if (t is RenderObject && hasLongPress(t)) {
        return (probe: null, reason: HelpQuietReason.nativeLongPress);
      }
    }
    // 3. Innermost interactive element (or explicit HelpTarget).
    RenderBox? target;
    int targetIndex = -1;
    for (var i = 0; i < path.length; i++) {
      final t = path[i];
      if (t is! RenderBox) continue;
      final isTag = t is RenderMetaData && t.metaData is HelpTargetTag;
      if (!isTag && !isInteractive(t)) continue;
      final r = _globalRect(t);
      if (r == null) continue;
      if (r.width < 8 || r.height < 8) continue;
      if (_tooBig(r, screen)) continue;
      target = t;
      targetIndex = i;
      break;
    }
    if (target == null) {
      return (probe: null, reason: HelpQuietReason.noTarget);
    }
    // Explicit id: the nearest HelpTarget around the target before another
    // interactive element starts.
    String? explicitId;
    for (var i = targetIndex; i < path.length; i++) {
      final t = path[i];
      if (t is RenderMetaData && t.metaData is HelpTargetTag) {
        explicitId = (t.metaData as HelpTargetTag).id;
        break;
      }
      if (i > targetIndex && t is RenderObject && isInteractive(t)) {
        final r = t is RenderBox ? _globalRect(t) : null;
        final tr = _globalRect(target);
        // Same element seen through another layer (e.g. button semantics
        // around its ink well) — keep looking.
        if (r != null && tr != null && _sameElement(r, tr)) continue;
        break;
      }
    }
    final visual = _visualBox(target);
    var rect = _globalRect(visual) ?? _globalRect(target)!;
    // Clip to the scrolling viewport the element sits in.
    for (var i = targetIndex + 1; i < path.length; i++) {
      final t = path[i];
      if (t is RenderViewportBase) {
        final vr = _globalRect(t);
        if (vr != null) {
          final clipped = rect.intersect(vr);
          if (clipped.width > 0 && clipped.height > 0) rect = clipped;
        }
        break;
      }
    }
    // 4. Read what the element shows (element tree: exact widgets).
    final texts = <String>[];
    final tooltips = <String>[];
    final icons = <Object>[];
    var hasTooltip = false;
    var editable = false;
    final element = _elementFor(target);
    if (element != null) {
      void collect(Element e) {
        final w = e.widget;
        if (e is RenderObjectElement &&
            !identical(e.renderObject, target) &&
            isInteractive(e.renderObject) &&
            !_isSameAsTarget(e.renderObject, target!)) {
          return; // nested element: has its own help.
        }
        if (w is EditableText) {
          editable = true;
          return;
        }
        if (w is Text) {
          final s = (w.data ?? w.textSpan?.toPlainText() ?? '').trim();
          if (s.isNotEmpty) texts.add(s);
          return;
        }
        if (w is RichText) {
          final s = w.text.toPlainText().trim();
          if (s.isNotEmpty) texts.add(s);
          return;
        }
        if (w is Icon) {
          if (w.icon != null) icons.add(w.icon!);
          return;
        }
        if (w is HugeIcon) {
          icons.add(w.icon);
          return;
        }
        if (w is TwoToneIcon) {
          icons.add(w.data);
          return;
        }
        if (w is Tooltip) {
          hasTooltip = true;
          final m = w.message;
          if (m != null && m.trim().isNotEmpty) tooltips.add(m.trim());
        }
        e.visitChildren(collect);
      }

      collect(element);
      // Tooltips / semantic labels sit AROUND buttons: walk up while still
      // on the same element.
      final tr = _globalRect(target)!;
      var depth = 0;
      element.visitAncestorElements((a) {
        if (++depth > 40) return false;
        if (a is RenderObjectElement) {
          final ro = a.renderObject;
          if (ro is RenderBox) {
            final r = _globalRect(ro);
            if (r != null && !_sameElement(r, tr)) return false;
          }
        }
        final w = a.widget;
        if (w is Tooltip) {
          hasTooltip = true;
          final m = w.message;
          if (m != null && m.trim().isNotEmpty) tooltips.add(m.trim());
        } else if (w is IconButton && w.tooltip != null) {
          tooltips.add(w.tooltip!.trim());
        } else if (w is FloatingActionButton && w.tooltip != null) {
          tooltips.add(w.tooltip!.trim());
        } else if (w is Semantics && w.properties.label != null) {
          final l = w.properties.label!.trim();
          if (l.isNotEmpty) tooltips.add(l);
        }
        return true;
      });
    }
    if (editable) {
      return (probe: null, reason: HelpQuietReason.editable);
    }
    // A bare toggle/checkbox/radio (no text, tooltip or label of its own)
    // is explained by the row it sits in: read the row's texts, but keep
    // the ring on the control itself.
    final lettered = RegExp(r'[A-Za-z\u0600-\u06FF]');
    if (element != null &&
        !texts.any(lettered.hasMatch) &&
        tooltips.isEmpty &&
        (_isToggle(target) || _insideToggleWidget(element))) {
      texts.addAll(_rowTexts(element, target, screen));
    }
    for (final t in path) {
      if (t is RenderSemanticsAnnotations && t.properties.tooltip != null) {
        hasTooltip = true;
      }
    }
    return (
      probe: HelpProbe(
        box: visual,
        boxOrigin: _globalRect(visual)?.topLeft ?? rect.topLeft,
        rect: rect,
        explicitId: explicitId,
        texts: _dedupe(texts),
        tooltips: _dedupe(tooltips),
        icons: icons,
        hasTooltip: hasTooltip,
        wide: rect.width >= screen.width * 0.6,
      ),
      reason: HelpQuietReason.none,
    );
  }

  static bool _insideToggleWidget(Element e) {
    var found = false;
    var depth = 0;
    e.visitAncestorElements((a) {
      if (++depth > 16) return false;
      final w = a.widget;
      if (w is Switch || w is Checkbox || w is Radio || w is CupertinoSwitch) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  static bool _isToggle(RenderObject o) {
    if (o is RenderSemanticsAnnotations) {
      final p = o.properties;
      return p.toggled != null || p.checked != null;
    }
    // Switch/Checkbox paint through their own render objects; their
    // semantics wrapper is the target.
    final n = o.runtimeType.toString();
    return n.contains('Switch') || n.contains('Checkbox') || n.contains('Radio');
  }

  /// Texts of the nearest row-sized ancestor of a bare control, skipping
  /// other interactive elements in that row.
  static List<String> _rowTexts(Element element, RenderBox target, Size screen) {
    final out = <String>[];
    final tr = _globalRect(target);
    if (tr == null) return out;
    Element? row;
    var depth = 0;
    element.visitAncestorElements((a) {
      if (++depth > 30) return false;
      if (a is RenderObjectElement && a.renderObject is RenderBox) {
        final r = _globalRect(a.renderObject as RenderBox);
        if (r == null) return true;
        if (r.height > 160 || _tooBig(r, screen)) return false;
        if (r.width > tr.width + 40) {
          row = a;
          // keep climbing while it is still one row tall
        }
      }
      return true;
    });
    final rowEl = row;
    if (rowEl == null) return out;
    void collect(Element e) {
      if (e is RenderObjectElement &&
          !identical(e.renderObject, target) &&
          isInteractive(e.renderObject) &&
          !_isSameAsTarget(e.renderObject, target) &&
          e.renderObject is RenderBox &&
          (_globalRect(e.renderObject as RenderBox)?.width ?? 0) <
              (tr.width + 40)) {
        return; // another small control in the row
      }
      final w = e.widget;
      if (w is Text) {
        final s = (w.data ?? w.textSpan?.toPlainText() ?? '').trim();
        if (s.isNotEmpty) out.add(s);
        return;
      }
      if (w is RichText) {
        final s = w.text.toPlainText().trim();
        if (s.isNotEmpty) out.add(s);
        return;
      }
      e.visitChildren(collect);
    }

    collect(rowEl);
    return out;
  }

  static List<String> _dedupe(List<String> l) {
    final out = <String>[];
    for (final s in l) {
      if (!out.contains(s)) out.add(s);
    }
    return out;
  }

  static bool _sameElement(Rect a, Rect b) =>
      (a.width - b.width).abs() <= 16 &&
      (a.height - b.height).abs() <= 16 &&
      (a.center - b.center).distance <= 12;

  static bool _isSameAsTarget(RenderObject o, RenderBox target) {
    if (o is! RenderBox) return false;
    final a = _globalRect(o);
    final b = _globalRect(target);
    if (a == null || b == null) return false;
    return _sameElement(a, b);
  }

  /// Material buttons pad themselves to a 48dp tap target; the ring must wrap
  /// the visible button, not that invisible padding.
  static RenderBox _visualBox(RenderBox target) {
    RenderObject? node = target;
    for (var i = 0; i < 8 && node != null; i++) {
      if (node.runtimeType.toString() == '_RenderInputPadding') {
        RenderBox? child;
        node.visitChildren((c) {
          if (c is RenderBox) child = c;
        });
        if (child != null && child!.hasSize) return child!;
        return target;
      }
      RenderObject? only;
      var count = 0;
      node.visitChildren((c) {
        count++;
        only = c;
      });
      if (count != 1) break;
      node = only;
    }
    return target;
  }

  static Element? _elementFor(RenderObject target) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    final ancestors = <RenderObject>{};
    RenderObject? r = target;
    while (r != null) {
      ancestors.add(r);
      r = r.parent;
    }
    Element? found;
    void visit(Element e, bool prune) {
      if (found != null) return;
      if (e is RenderObjectElement) {
        final ro = e.renderObject;
        if (identical(ro, target)) {
          found = e;
          return;
        }
        if (prune && !ancestors.contains(ro)) return;
      }
      e.visitChildren((c) => visit(c, prune));
    }

    visit(root, true);
    // Overlay portals re-parent render objects: retry without pruning.
    if (found == null) visit(root, false);
    return found;
  }
}
