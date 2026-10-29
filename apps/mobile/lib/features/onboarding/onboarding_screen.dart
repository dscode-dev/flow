import 'package:flutter/material.dart';

import '../auth/auth_screens.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final handle = TextEditingController();
  bool initialized = false;
  @override
  void dispose() {
    name.dispose();
    handle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AuthView(
    tick: true,
    builder: (context, auth, state) {
      if (!initialized && state.user != null) {
        initialized = true;
        name.text = state.user!.displayName;
        handle.text = state.user!.handle ?? '';
      }
      void submit() {
        if (form.currentState!.validate()) {
          FocusScope.of(context).unfocus();
          auth.completeOnboarding(name.text, handle.text);
        }
      }

      return AuthLayout(
        eyebrow: 'Seu perfil',
        title: 'Como você quer\nser conhecido?',
        description: 'Escolha seu nome e um nome de usuário. O Flow confirma a disponibilidade ao salvar.',
        busy: state.busy,
        children: [
          AuthFeedback(state),
          Form(
            key: form,
            child: Column(
              children: [
                TextFormField(
                  controller: name,
                  enabled: !state.busy,
                  decoration: const InputDecoration(
                    labelText: 'Nome de exibição',
                  ),
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  validator: (s) =>
                      s == null ||
                          s.trim().isEmpty ||
                          s.trim().runes.length > 80
                      ? 'Use um nome de 1 a 80 caracteres.'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: handle,
                  enabled: !state.busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Nome de usuário',
                    prefixText: '@',
                    helperText:
                        'De 3 a 30 letras, números ou _. Comece com uma letra.',
                  ),
                  textInputAction: TextInputAction.done,
                  validator: (s) =>
                      RegExp(r'^[a-z][a-z0-9_]{2,29}$')
                          .hasMatch((s ?? '').trim().toLowerCase())
                      ? null
                      : 'Confira o formato do nome de usuário.',
                  onFieldSubmitted: (_) {
                    if (auth.canSubmit) submit();
                  },
                ),
              ],
            ),
          ),
          if (state.retryAt != null && auth.now().isBefore(state.retryAt!))
            Text(
              'Nova tentativa em ${remaining(state.retryAt!, auth.now())} s.',
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: auth.canSubmit ? submit : null,
            child: const Text('Concluir perfil'),
          ),
          TextButton(
            onPressed: state.busy ? null : auth.revalidate,
            child: const Text('Verificar perfil já salvo'),
          ),
          TextButton(
            onPressed: state.busy ? null : auth.signOut,
            child: const Text('Sair da conta'),
          ),
        ],
      );
    },
  );
}
