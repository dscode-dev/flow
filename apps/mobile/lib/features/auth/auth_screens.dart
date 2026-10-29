import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../design/tokens.dart';
import 'legal_links.dart';

class AuthLayout extends StatelessWidget {
  const AuthLayout({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.children,
    this.back,
    this.busy = false,
  });
  final String eyebrow, title, description;
  final List<Widget> children;
  final VoidCallback? back;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flow'),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        leading: back == null
            ? null
            : IconButton(
                onPressed: busy ? null : back,
                tooltip: 'Voltar',
                icon: const Icon(Icons.arrow_back_rounded),
              ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ExcludeSemantics(
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          gradient: FlowColors.accent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      eyebrow.toUpperCase(),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: theme.textTheme.headlineLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                          letterSpacing: -0.7,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      description,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 32),
                    ...children,
                    if (busy) ...[
                      const SizedBox(height: 20),
                      Semantics(
                        liveRegion: true,
                        label: 'Processando solicitação',
                        child: LinearProgressIndicator(
                          value: MediaQuery.disableAnimationsOf(context)
                              ? 0.5
                              : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuthFeedback extends StatelessWidget {
  const AuthFeedback(this.state, {super.key});
  final AuthState state;
  @override
  Widget build(BuildContext context) {
    final message = state.issue?.message ?? state.notice;
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(
                color: state.issue == null
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            if (state.issue?.requestId case final id?)
              Text(
                'Referência para suporte: $id',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class AuthView extends ConsumerStatefulWidget {
  const AuthView({super.key, required this.builder, this.tick = false});
  final Widget Function(BuildContext, AuthController, AuthState) builder;
  final bool tick;
  @override
  ConsumerState<AuthView> createState() => _AuthViewState();
}

class _AuthViewState extends ConsumerState<AuthView> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    if (widget.tick) {
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(authControllerProvider);
    return ValueListenableBuilder<AuthState>(
      valueListenable: controller,
      builder: (context, state, _) =>
          widget.builder(context, controller, state),
    );
  }
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context) => AuthView(
    tick: true,
    builder: (context, auth, state) => AuthLayout(
      eyebrow: 'Viva novas conexões',
      title: 'Seu próximo encontro\ncomeça aqui.',
      description: 'Entre no Flow para criar seu perfil e se preparar para novas experiências.',
      busy: state.busy,
      children: [
        const Text('Como você quer continuar?'),
        const SizedBox(height: 16),
        AuthFeedback(state),
        FilledButton.icon(
          onPressed: auth.canRequest ? () => context.go('/phone') : null,
          icon: const Icon(Icons.phone_outlined),
          label: const Text('Continuar com telefone'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: auth.canRequest ? () => auth.signInSocial('GOOGLE') : null,
          child: const Text('Continuar com Google'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: auth.canRequest ? () => auth.signInSocial('APPLE') : null,
          icon: const Icon(Icons.apple),
          label: const Text('Continuar com Apple'),
        ),
        if (state.retryAt != null && auth.now().isBefore(state.retryAt!)) ...[
          const SizedBox(height: 12),
          Text(
            'Aguarde ${remaining(state.retryAt!, auth.now())} s antes de tentar novamente.',
          ),
        ],
        const SizedBox(height: 28),
        Text(
          'Já tem uma conta? Use um método vinculado a ela.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        const LegalLinks(),
      ],
    ),
  );
}

int remaining(DateTime until, DateTime now) =>
    ((until.difference(now).inMilliseconds / 1000).ceil()).clamp(0, 999999);

class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});
  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final form = GlobalKey<FormState>();
  final country = TextEditingController(text: '+55');
  final phone = TextEditingController();
  @override
  void dispose() {
    country.dispose();
    phone.dispose();
    super.dispose();
  }

  String get normalized {
    final input = phone.text.trim();
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    return input.startsWith('+')
        ? '+$digits'
        : '+${country.text.replaceAll(RegExp(r'[^0-9]'), '')}$digits';
  }

  @override
  Widget build(BuildContext context) => AuthView(
    tick: true,
    builder: (context, auth, state) {
      void submit() {
        if (form.currentState!.validate()) {
          FocusScope.of(context).unfocus();
          unawaited(auth.startPhone(normalized));
        }
      }

      return AuthLayout(
        eyebrow: 'Seu telefone',
        title: 'Vamos enviar\num código.',
        description: 'Informe seu número com DDD. Você também pode usar um número internacional com + e código do país.',
        back: () {
          auth.backToWelcome();
          context.go('/welcome');
        },
        busy: state.busy,
        children: [
          AuthFeedback(state),
          Form(
            key: form,
            child: AutofillGroup(
              child: Column(
                children: [
                  TextFormField(
                    controller: country,
                    enabled: !state.busy,
                    decoration: const InputDecoration(
                      labelText: 'Código do país',
                      helperText: 'Brasil: +55. Altere para outro país.',
                    ),
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    validator: (_) =>
                        RegExp(r'^\+?[1-9][0-9]{0,2}$')
                            .hasMatch(country.text.trim())
                        ? null
                        : 'Informe um código de país válido.',
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: phone,
                    enabled: !state.busy,
                    decoration: const InputDecoration(
                      labelText: 'Telefone com DDD',
                      hintText: '(81) 99999-9999',
                    ),
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    validator: (_) =>
                        RegExp(r'^\+[1-9][0-9]{6,14}$').hasMatch(normalized)
                        ? null
                        : 'Confira o número e o código do país.',
                    onFieldSubmitted: (_) {
                      if (auth.canRequest) submit();
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: auth.canRequest ? submit : null,
            child: const Text('Solicitar código'),
          ),
          if (state.retryAt != null && auth.now().isBefore(state.retryAt!)) ...[
            const SizedBox(height: 12),
            Text(
              'Nova tentativa em ${remaining(state.retryAt!, auth.now())} s.',
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'A solicitação não confirma a entrega do SMS. O serviço valida os países atendidos.',
          ),
        ],
      );
    },
  );
}

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});
  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final code = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AuthView(
    tick: true,
    builder: (context, auth, state) {
      final challenge = state.challenge;
      final seconds = challenge == null
          ? 0
          : remaining(challenge.expiresAt, auth.now());
      final cooldown = state.retryAt == null
          ? 0
          : remaining(state.retryAt!, auth.now());
      return AuthLayout(
        eyebrow: 'Confirme seu número',
        title: 'Confira seu SMS.',
        description: 'Digite o código da solicitação mais recente. Não compartilhe esse código.',
        back: () {
          auth.backToWelcome();
          context.go('/phone');
        },
        busy: state.busy,
        children: [
          AuthFeedback(state),
          Form(
            key: form,
            child: TextFormField(
              controller: code,
              enabled: auth.canVerify && seconds > 0,
              decoration: const InputDecoration(
                labelText: 'Código de verificação',
              ),
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              autofillHints: const [AutofillHints.oneTimeCode],
              validator: (value) =>
                  RegExp(r'^[0-9]{4,10}$').hasMatch(value ?? '')
                  ? null
                  : 'Informe o código recebido por SMS.',
              onFieldSubmitted: (_) {
                if (!state.busy &&
                    seconds > 0 &&
                    form.currentState!.validate()) {
                  unawaited(auth.verifyPhone(code.text));
                }
              },
            ),
          ),
          const SizedBox(height: 16),
          Text(
            seconds > 0
                ? 'Código válido por $seconds s.'
                : 'Esta tentativa expirou. Solicite um novo código.',
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: !auth.canVerify || seconds == 0
                ? null
                : () {
                    if (form.currentState!.validate()) {
                      FocusScope.of(context).unfocus();
                      unawaited(auth.verifyPhone(code.text));
                    }
                  },
            child: const Text('Confirmar código'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: !state.busy && cooldown == 0
                ? () {
                    code.clear();
                    unawaited(auth.resendPhone());
                  }
                : null,
            child: Text(
              cooldown > 0
                  ? 'Reenviar em $cooldown s'
                  : 'Solicitar novo código',
            ),
          ),
          TextButton(
            onPressed: state.busy
                ? null
                : () {
                    auth.backToWelcome();
                    context.go('/phone');
                  },
            child: const Text('Usar outro número'),
          ),
        ],
      );
    },
  );
}

class SessionGateScreen extends StatelessWidget {
  const SessionGateScreen({super.key});
  @override
  Widget build(BuildContext context) => AuthView(
    builder: (context, auth, state) => AuthLayout(
      eyebrow: 'Sua conta',
      title: state.status == AuthStatus.restricted
          ? 'Acesso restrito.'
          : state.status == AuthStatus.error
          ? 'Não foi possível continuar.'
          : 'Preparando seu Flow.',
      description: state.busy
          ? 'Estamos verificando sua sessão com segurança.'
          : 'Confira a orientação abaixo para continuar.',
      busy: state.busy,
      children: [
        AuthFeedback(state),
        if (!state.busy) ...[
          if (state.status == AuthStatus.error &&
              state.issue?.code != 'storage')
            FilledButton(
              onPressed: auth.revalidate,
              child: const Text('Verificar sessão novamente'),
            ),
          TextButton(
            onPressed: auth.signOut,
            child: Text(
              state.issue?.code == 'storage'
                  ? 'Limpar sessão e tentar novamente'
                  : 'Sair deste aparelho',
            ),
          ),
        ],
      ],
    ),
  );
}

class DevelopmentShell extends StatelessWidget {
  const DevelopmentShell({super.key});
  @override
  Widget build(BuildContext context) => AuthView(
    builder: (context, auth, state) => AuthLayout(
      eyebrow: 'Ambiente de desenvolvimento',
      title: 'Você entrou, ${state.user?.displayName ?? ''}.',
      description: 'Autenticação e perfil inicial confirmados. As experiências do Flow serão implementadas nas próximas etapas.',
      busy: state.busy,
      children: [
        if (state.user?.handle case final handle?) Text('@$handle'),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: auth.signOut,
          child: const Text('Sair da conta'),
        ),
      ],
    ),
  );
}
