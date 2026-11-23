# Meow — projeto inicial Flutter

Este pacote contém a primeira base de interface do Meow.

## O que já existe
- Tema escuro com detalhes roxos e identidade Meow.
- Navegação entre canais, amigos e perfil.
- Lista demonstrativa de servidores e canais.
- Prévia de sala de voz.

## O que ainda NÃO existe
Esta é uma primeira versão de interface. Ainda não há:
- Login real ou contas.
- Banco de dados/backend.
- Mensagens enviadas pela internet.
- Amigos reais ou convites.
- Áudio em tempo real.
- Compartilhamento de tela.
- APK compilado.

## Como abrir
É necessário ter o Flutter SDK instalado em um ambiente de desenvolvimento:
1. `flutter pub get`
2. `flutter run`

Para gerar APK Android:
`flutter build apk --release`

Para iOS, a compilação final normalmente exige macOS com Xcode.

## Próxima etapa
Configurar o ambiente de compilação, depois conectar autenticação e dados. A transmissão de tela será integrada posteriormente com uma solução de áudio/vídeo em tempo real e permissões nativas Android/iOS.
