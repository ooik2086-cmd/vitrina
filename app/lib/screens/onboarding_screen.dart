import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n.dart';
import '../my_size.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/size_guide.dart';

const _prefsKey = 'vitrina_onboarded';

/// True once the person has seen the three intro pages; stays true when nothing was restored, so tests and
/// embedded screens never meet them.
final onboarded = ValueNotifier<bool>(true);

Future<void> restoreOnboarded() async {
  try {
    onboarded.value = (await SharedPreferences.getInstance()).getBool(_prefsKey) ?? false;
  } catch (_) {
    onboarded.value = true; // without storage the intro would come back on every launch
  }
}

Future<void> finishOnboarding() async {
  onboarded.value = true;
  forgetOnboardingPage(); // a later intro (storage lost) starts at the beginning
  try {
    await (await SharedPreferences.getInstance()).setBool(_prefsKey, true);
  } catch (_) {}
}

class _Page {
  const _Page(this.icon, this.title, this.text);
  final IconData icon;
  final String title;
  final String text;
}

const _pages = [
  _Page(Icons.threesixty_rounded, 'Аяқкиімді 360° айналдырып көріңіз',
      '360° белгісі бар аяқкиімді саусақпен кез келген жаққа бұрап, екі саусақпен жақындатыңыз. Тігісі мен табанына дейін көресіз.'),
  _Page(Icons.verified_user_outlined, 'Ақшаңыз қорғалған',
      'Төлем VITRINA-да сақталады. Сатушы оны тауарды алғаныңызды растағаннан кейін ғана алады.'),
  _Page(Icons.straighten_rounded, 'Өлшеміңізді бір рет көрсетіңіз',
      'Табан ұзындығын сантиметрмен енгізсеңіз, каталог пен тауар беті сізге сай өлшемді бірден көрсетеді.'),
];

// The second page while online payment is off: nothing is held, so nothing is promised.
const _directPage = _Page(Icons.chat_bubble_outline_rounded, 'Сатушымен тікелей келісіңіз',
    'Онлайн төлем әзірге қосылмаған. Тауар бетінде «Сатушыға жазу» басып, төлем мен жеткізуді чатта келісіңіз. Тауарды қолыңызға алғанда төлеген қауіпсіз.');

/// Three short pages on first launch: what the 360° showcase is, why paying here is safe, and the buyer's size.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

/// Where the person was, kept across a language change (it builds the app anew): not back to page 1.
int _keptPage = 0;
bool? _keptPayments;

@visibleForTesting
void forgetOnboardingPage() {
  _keptPage = 0;
  _keptPayments = null;
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final _pager = PageController(initialPage: _keptPage);
  int _page = _keptPage;
  bool? _payments = _keptPayments; // what the server said; until then neither money page is shown

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Without a session (this page tested alone) the pages stay as they are.
    SessionScope.maybeOf(context)?.api.paymentsPromised().then((on) {
      // Not under the person's eyes: once past the first page the pages stay as they are.
      if (mounted && on != _payments && _page == 0) setState(() => _payments = _keptPayments = on);
    });
  }

  List<_Page> get _shown => switch (_payments) {
        true => _pages,
        false => [_pages[0], _directPage, _pages[2]],
        null => [_pages[0], _pages[2]],
      };

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _shown.length - 1) {
      finishOnboarding();
    } else {
      _pager.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _page == _shown.length - 1;
    // Back on a later page goes to the page before, as a finger swiping back would; on the first it leaves.
    return PopScope(
        canPop: _page == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _pager.previousPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
        },
        child: Scaffold(
          body: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(children: [
                  const Expanded(child: Align(alignment: Alignment.centerLeft, child: LanguageSwitch())),
                  TextButton(key: const Key('onboarding-skip'), onPressed: finishOnboarding, child: Text(tr('Өткізу'))),
                ]),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pager,
                  itemCount: _shown.length,
                  onPageChanged: (i) => setState(() => _page = _keptPage = i),
                  itemBuilder: (context, i) => _PageBody(page: _shown[i], showSize: i == _shown.length - 1),
                ),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < _shown.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _page ? Brand.accent : theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                child: SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton(
                    key: const Key('onboarding-next'),
                    onPressed: _next,
                    child: Text(last ? tr('Бастау') : tr('Келесі')),
                  ),
                ),
              ),
            ]),
          ),
        ));
  }
}

class _PageBody extends StatelessWidget {
  const _PageBody({required this.page, required this.showSize});
  final _Page page;
  final bool showSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scrolls when a small phone or large text leaves too little room; centred otherwise, as before.
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 168,
              height: 168,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Brand.studio,
                border: Border.all(color: Brand.accent.withValues(alpha: 0.35), width: 2),
              ),
              child: Icon(page.icon, size: 76, color: Brand.ink),
            ),
            const SizedBox(height: 36),
            Text(tr(page.title), textAlign: TextAlign.center, style: weight(theme.textTheme.headlineSmall!, 750)),
            const SizedBox(height: 14),
            Text(tr(page.text),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.45)),
            if (showSize) ...[
              const SizedBox(height: 24),
              ValueListenableBuilder<String?>(
                valueListenable: mySize,
                builder: (context, size, _) => OutlinedButton.icon(
                  key: const Key('onboarding-size'),
                  onPressed: () => showSizeGuide(context),
                  icon: Icon(size == null ? Icons.add_rounded : Icons.check_rounded, size: 18),
                  label: Text(size == null ? tr('Өлшемімді көрсету') : trf('Өлшеміңіз: {0} см', [size])),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
