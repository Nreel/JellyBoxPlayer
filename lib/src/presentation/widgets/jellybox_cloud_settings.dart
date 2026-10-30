import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/domain/providers/cloud_provider.dart';
import 'package:jplayer/src/presentation/widgets/form_modal.dart';
import 'package:jplayer/src/presentation/widgets/jellybox_cloud_connect_form.dart';
import 'package:jplayer/src/presentation/widgets/labeled_text_field.dart';
import 'package:jplayer/src/presentation/widgets/server_address_settings.dart';

Future<void> connectJellyboxCloud(BuildContext context) async {
  await showFormModal<bool>(
    context,
    builder: (context) => const JellyboxCloudConnectForm(),
  );
}

class JellyboxCloudSettings extends ConsumerWidget {
  const JellyboxCloudSettings({super.key});

  static final ButtonStyle _buttonStyle = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  );

  void _editHome(BuildContext context) => unawaited(
    showFormModal<void>(
      context,
      builder: (context) => const ContinuityAddressForm(homeField: true),
    ),
  );

  void _editRemote(BuildContext context) => unawaited(
    showFormModal<void>(
      context,
      builder: (context) => const ContinuityAddressForm(homeField: false),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(cloudProvider).account;
    final addresses = ref.watch(conductorUrlProvider);
    final remote = addresses.remote;
    final muted = Theme.of(
      context,
    ).colorScheme.onPrimary.withValues(alpha: 0.7);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        AddressRow(
          label: 'Home',
          address: addresses.home,
          active: addresses.active == addresses.home,
          muted: muted,
          actions: [
            ActionIcon(
              icon: Icons.edit_outlined,
              tooltip: 'Change continuity server address',
              onPressed: () => _editHome(context),
            ),
          ],
        ),
        if (remote == null)
          TextButton.icon(
            onPressed: () => _editRemote(context),
            style: _buttonStyle,
            icon: const Icon(Icons.add_link),
            label: const Text('Add remote address'),
          )
        else
          AddressRow(
            label: 'Remote',
            address: remote,
            active: addresses.active == remote,
            muted: muted,
            actions: [
              ActionIcon(
                icon: Icons.edit_outlined,
                tooltip: 'Change remote address',
                onPressed: () => _editRemote(context),
              ),
              ActionIcon(
                icon: Icons.delete_outline,
                tooltip: 'Remove remote address',
                onPressed: () =>
                    ref.read(conductorUrlProvider.notifier).setRemote(null),
              ),
            ],
          ),
        if (account case final acct?)
          Row(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: () => unawaited(connectJellyboxCloud(context)),
                style: _buttonStyle,
                icon: const Icon(Icons.cloud_done),
                label: Text('Connected as ${acct.login}'),
              ),
              const Icon(Icons.check, size: 16),
              ActionIcon(
                icon: Icons.logout,
                tooltip: 'Disconnect from Jellybox Cloud',
                onPressed: () =>
                    unawaited(ref.read(cloudProvider.notifier).signOut()),
              ),
            ],
          )
        else
          TextButton.icon(
            onPressed: () => unawaited(connectJellyboxCloud(context)),
            style: _buttonStyle,
            icon: const Icon(Icons.cloud_outlined),
            label: const Text('Connect'),
          ),
      ],
    );
  }
}

/// Edits one address of the continuity server. The home variant must name a
/// server; the remote variant may be left empty, which removes it.
class ContinuityAddressForm extends ConsumerStatefulWidget {
  const ContinuityAddressForm({
    required this.homeField,
    this.padding = const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
    super.key,
  });

  static const emptyError = 'Enter the continuity server address.';

  final bool homeField;
  final EdgeInsets padding;

  @override
  ConsumerState<ContinuityAddressForm> createState() =>
      _ContinuityAddressFormState();
}

class _ContinuityAddressFormState extends ConsumerState<ContinuityAddressForm> {
  late final _controller = TextEditingController(
    text: widget.homeField
        ? ref.read(conductorUrlProvider).home
        : ref.read(conductorUrlProvider).remote ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (widget.homeField && text.isEmpty) {
      setState(() => _error = ContinuityAddressForm.emptyError);
      return;
    }
    final notifier = ref.read(conductorUrlProvider.notifier);
    if (widget.homeField) {
      notifier.setHome(text);
    } else {
      notifier.setRemote(text.isEmpty ? null : text);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      minimum: widget.padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ModalFormHeader(
            widget.homeField ? 'Continuity server address' : 'Remote address',
          ),
          const SizedBox(height: 8),
          Text(
            widget.homeField
                ? 'The main address of your continuity server. Change it when '
                      'the server moved to a new IP or port.'
                : 'A second address for the same continuity server, such as a '
                      'Tailscale, WireGuard or reverse proxy URL. Jellybox '
                      'uses the home address when it answers and switches to '
                      'this one when it does not.',
            style: TextStyle(
              fontSize: 14,
              color: theme.colorScheme.onPrimary.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          LabeledTextField(
            controller: _controller,
            placeholder: widget.homeField
                ? 'http://192.168.1.10:8000'
                : 'https://jellybox.example.ts.net:8000',
            keyboardType: TextInputType.url,
            autofocus: true,
            textInputAction: TextInputAction.done,
          ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error,
                style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          ModalFormActions(
            submitLabel: 'Save',
            onSubmit: () => unawaited(_submit()),
          ),
        ],
      ),
    );
  }
}
