import 'package:flutter/material.dart';

void main() => runApp(const MeowApp());

const bg = Color(0xFF111218);
const panel = Color(0xFF191A23);
const panel2 = Color(0xFF222431);
const purple = Color(0xFF8B5CF6);
const muted = Color(0xFF9A9BAD);

class MeowApp extends StatelessWidget {
  const MeowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: purple,
          brightness: Brightness.dark,
          surface: panel,
        ),
        useMaterial3: true,
      ),
      home: const MeowHome(),
    );
  }
}

class MeowHome extends StatefulWidget {
  const MeowHome({super.key});

  @override
  State<MeowHome> createState() => _MeowHomeState();
}

class _MeowHomeState extends State<MeowHome> {
  int selectedServer = 0;
  int selectedTab = 0;
  int selectedChannel = 0;

  final channels = const [
    ('geral', Icons.tag),
    ('avisos', Icons.campaign_outlined),
    ('bate-papo', Icons.tag),
    ('Sala de voz', Icons.volume_up_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _serverRail(),
            Expanded(
              child: Column(
                children: [
                  _topBar(),
                  Expanded(
                    child: selectedTab == 1
                        ? _friendsPage()
                        : selectedTab == 2
                            ? _profilePage()
                            : _chatPage(),
                  ),
                  _bottomNav(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _serverRail() {
    return Container(
      width: 66,
      color: const Color(0xFF0C0D12),
      child: Column(
        children: [
          const SizedBox(height: 12),
          _serverButton('M', 0, isHome: true),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 9),
            child: SizedBox(width: 28, child: Divider(color: panel2)),
          ),
          _serverButton('G', 1),
          _serverButton('F', 2),
          const Spacer(),
          _serverButton('+', 3, isAdd: true),
          const SizedBox(height: 14),
        ],
      ),
    );
  }

  Widget _serverButton(String label, int index,
      {bool isHome = false, bool isAdd = false}) {
    final selected = selectedServer == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => setState(() {
          selectedServer = index;
          selectedTab = 0;
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: selected ? purple : (isAdd ? panel2 : panel),
            borderRadius: BorderRadius.circular(selected ? 15 : 23),
            border: selected
                ? Border.all(color: Colors.white.withOpacity(.18))
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: isAdd && !selected ? const Color(0xFF6EE7B7) : Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final title = selectedTab == 1
        ? 'Amigos'
        : selectedTab == 2
            ? 'Meu perfil'
            : selectedServer == 0
                ? 'Meow'
                : selectedServer == 1
                    ? 'Game Zone'
                    : selectedServer == 2
                        ? 'Amigos'
                        : 'Novo servidor';
    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: panel,
        border: Border(bottom: BorderSide(color: Color(0xFF292B38))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          IconButton(
            tooltip: 'Pesquisar',
            onPressed: () => _notice('A pesquisa será adicionada futuramente.'),
            icon: const Icon(Icons.search, color: muted),
          ),
          const CircleAvatar(
            radius: 16,
            backgroundColor: purple,
            child: Text('M',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _chatPage() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
          color: panel,
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('CANAIS DE TEXTO',
                  style: TextStyle(
                      color: muted,
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
            ],
          ),
        ),
        Container(
          color: panel,
          child: Column(
            children: List.generate(channels.length, (i) {
              final item = channels[i];
              final active = selectedChannel == i;
              return ListTile(
                dense: true,
                selected: active,
                selectedTileColor: purple.withOpacity(.16),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Icon(item.$2,
                    size: 19, color: active ? Colors.white : muted),
                title: Text(item.$1,
                    style: TextStyle(
                        color: active ? Colors.white : muted,
                        fontWeight:
                            active ? FontWeight.w700 : FontWeight.w500)),
                onTap: () {
                  setState(() => selectedChannel = i);
                  if (i == 3) _openVoiceRoom();
                },
              );
            }),
          ),
        ),
        Expanded(
          child: selectedChannel == 3
              ? _voicePlaceholder()
              : _messagesPlaceholder(),
        ),
        if (selectedChannel != 3) _messageComposer(),
      ],
    );
  }

  Widget _messagesPlaceholder() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const SizedBox(height: 22),
        const Center(
          child: CircleAvatar(
            radius: 30,
            backgroundColor: purple,
            child: Icon(Icons.tag, size: 30, color: Colors.white),
          ),
        ),
        const SizedBox(height: 14),
        const Center(
          child: Text('Bem-vindo ao #geral',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 7),
        const Center(
          child: Text('Este é o começo da sua comunidade.',
              style: TextStyle(color: muted)),
        ),
        const SizedBox(height: 30),
        _message('Meow', 'Seu espaço para conversar começa aqui.', true),
        _message('Sistema',
            'As mensagens reais serão conectadas ao servidor na próxima etapa.',
            false),
      ],
    );
  }

  Widget _message(String name, String content, bool owner) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: owner ? purple : panel2,
            child: Icon(owner ? Icons.pets : Icons.smart_toy_outlined, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(content, style: const TextStyle(color: muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageComposer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      color: bg,
      child: Row(
        children: [
          IconButton(
            onPressed: () => _notice('Anexos serão adicionados futuramente.'),
            icon: const Icon(Icons.add_circle_outline, color: muted),
          ),
          const Expanded(
            child: TextField(
              enabled: false,
              decoration: InputDecoration(
                hintText: 'Mensagens serão ativadas na próxima etapa',
                filled: true,
                fillColor: panel,
                border: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.all(Radius.circular(14)),
                ),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),
          IconButton(
            onPressed: () =>
                _notice('O envio de mensagens será conectado ao backend.'),
            icon: const Icon(Icons.send_rounded, color: purple),
          ),
        ],
      ),
    );
  }

  Widget _voicePlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.graphic_eq, size: 54, color: purple),
            const SizedBox(height: 16),
            const Text('Sala de voz',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'A interface está pronta. Áudio ao vivo e transmissão de tela serão integrados depois.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, height: 1.5),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _openVoiceRoom,
              icon: const Icon(Icons.call),
              label: const Text('Ver sala de voz'),
              style: FilledButton.styleFrom(backgroundColor: purple),
            ),
          ],
        ),
      ),
    );
  }

  Widget _friendsPage() {
    final friends = [
      ('A', 'Alex', 'Online'),
      ('M', 'Marina', 'Ausente'),
      ('R', 'Rafael', 'Offline'),
    ];
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text('SEUS AMIGOS',
            style: TextStyle(
                color: muted, fontSize: 11, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ...friends.map((f) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: purple.withOpacity(.8),
                child: Text(f.$1),
              ),
              title: Text(f.$2),
              subtitle: Text(f.$3, style: const TextStyle(color: muted)),
              trailing: IconButton(
                icon: const Icon(Icons.chat_bubble_outline, color: muted),
                onPressed: () =>
                    _notice('Mensagens privadas serão implementadas.'),
              ),
            )),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: () =>
              _notice('Convites de amigos serão implementados.'),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('Adicionar amigo'),
        ),
      ],
    );
  }

  Widget _profilePage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircleAvatar(
            radius: 42,
            backgroundColor: purple,
            child: Icon(Icons.pets, size: 34, color: Colors.white),
          ),
          const SizedBox(height: 14),
          const Text('Seu perfil',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
          const Text('Configure seu perfil futuramente',
              style: TextStyle(color: muted)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () =>
                _notice('Configurações serão adicionadas depois.'),
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Configurações'),
          ),
        ],
      ),
    );
  }

  Widget _bottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: panel,
        border: Border(top: BorderSide(color: Color(0xFF292B38))),
      ),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _navItem(Icons.chat_bubble_outline, 'Canais', 0),
          _navItem(Icons.people_outline, 'Amigos', 1),
          _navItem(Icons.person_outline, 'Perfil', 2),
        ],
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int tab) {
    final active = selectedTab == tab;
    return InkWell(
      onTap: () => setState(() => selectedTab = tab),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: active ? purple : muted),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                    fontSize: 10, color: active ? Colors.white : muted)),
          ],
        ),
      ),
    );
  }

  void _openVoiceRoom() {
    showModalBottomSheet(
      context: context,
      backgroundColor: panel,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.headset_mic, color: purple, size: 42),
            const SizedBox(height: 12),
            const Text('Sala de voz',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Esta é uma prévia da interface. A conexão de áudio e a transmissão ainda não estão implementadas.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, height: 1.45),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                style: FilledButton.styleFrom(backgroundColor: purple),
                child: const Text('Entendi'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: panel2,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
