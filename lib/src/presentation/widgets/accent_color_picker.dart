import 'package:flutter/material.dart';
import 'package:jplayer/src/presentation/themes/themes.dart';
import 'package:jplayer/src/presentation/widgets/adaptive_dialog_action.dart';

/// HSV picker for the app accent colour.
///
/// Pops with the applied [Color], [Themes.defaultAccent] when reset, or
/// null when cancelled.
class AccentColorDialog extends StatefulWidget {
  const AccentColorDialog({required this.initial, super.key});

  final Color initial;

  @override
  State<AccentColorDialog> createState() => _AccentColorDialogState();
}

class _AccentColorDialogState extends State<AccentColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _hsv.toColor();

    return AlertDialog.adaptive(
      title: const Text('Accent colour', textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.onPrimary.withValues(alpha: 0.25),
              ),
            ),
          ),
          _slider(
            context,
            'Hue',
            _hsv.hue,
            0,
            360,
            (value) => setState(() => _hsv = _hsv.withHue(value)),
          ),
          _slider(
            context,
            'Saturation',
            _hsv.saturation,
            0.2,
            1,
            (value) => setState(() => _hsv = _hsv.withSaturation(value)),
          ),
          _slider(
            context,
            'Brightness',
            _hsv.value,
            0.4,
            1,
            (value) => setState(() => _hsv = _hsv.withValue(value)),
          ),
        ],
      ),
      actions: [
        AdaptiveDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        AdaptiveDialogAction(
          onPressed: () => Navigator.of(context).pop(Themes.defaultAccent),
          child: const Text('Reset'),
        ),
        AdaptiveDialogAction(
          onPressed: () => Navigator.of(context).pop(color),
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _slider(
    BuildContext context,
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) => Row(
    children: [
      SizedBox(
        width: 90,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            height: 1.2,
            color: Theme.of(context).colorScheme.onPrimary.withValues(
              alpha: 0.7,
            ),
          ),
        ),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ),
    ],
  );
}
