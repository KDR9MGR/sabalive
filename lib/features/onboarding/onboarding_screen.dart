import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

import '../../core/widgets/aurora_background.dart';
import '../../core/widgets/gradient_button.dart';
import '../../theme/app_colors.dart';
import '../../state/auth_controller.dart';

class _Page {
  const _Page(this.icon, this.title, this.body, this.accent);
  final IconData icon;
  final String title;
  final String body;
  final Color accent;
}

const _pages = [
  _Page(Icons.podcasts_rounded, 'Go Live.\nBe a Star!',
      'Broadcast your moments, connect with fans and grow your community worldwide.',
      AppColors.primary),
  _Page(Icons.videocam_rounded, 'Connect & Chat',
      'Make real connections through live chat, video calls and private messages.',
      AppColors.magenta),
  _Page(Icons.card_giftcard_rounded, 'Send Gifts,\nSpread Love',
      'Support your favourite creators with virtual gifts and climb the rankings.',
      AppColors.gold),
];

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  void _finish() => context.read<AuthController>().completeOnboarding();

  void _next() {
    if (_index == _pages.length - 1) {
      _finish();
    } else {
      _controller.nextPage(
          duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _index == _pages.length - 1;
    return Scaffold(
      body: AuroraBackground(
        intensity: 0.8,
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 16, 0),
                  child: TextButton(
                    onPressed: _finish,
                    child: const Text('Skip',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => _OnboardPageView(page: _pages[i]),
                ),
              ),
              SmoothPageIndicator(
                controller: _controller,
                count: _pages.length,
                effect: const ExpandingDotsEffect(
                  activeDotColor: AppColors.primaryBright,
                  dotColor: AppColors.stroke,
                  dotHeight: 8,
                  dotWidth: 8,
                  expansionFactor: 3,
                ),
              ),
              const SizedBox(height: 28),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: GradientButton(
                  label: last ? 'Get Started' : 'Next',
                  onPressed: _next,
                ),
              ),
              SizedBox(
                height: 48,
                child: last
                    ? null
                    : TextButton(
                        onPressed: _finish,
                        child: const Text('Skip',
                            style: TextStyle(color: AppColors.textMuted)),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardPageView extends StatelessWidget {
  const _OnboardPageView({required this.page});
  final _Page page;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [page.accent.withValues(alpha: 0.35), Colors.transparent],
              ),
            ),
            child: Center(
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.primaryGradient,
                  boxShadow: [
                    BoxShadow(
                      color: page.accent.withValues(alpha: 0.5),
                      blurRadius: 40,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Icon(page.icon, size: 54, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 44),
          Text(
            page.title,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .displaySmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          Text(
            page.body,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.textSecondary, height: 1.6, fontSize: 14.5),
          ),
        ],
      ),
    );
  }
}
