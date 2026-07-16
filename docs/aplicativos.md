# Aplicativos Android e iPhone

O aplicativo de telemetria usa Flutter e compartilha o mesmo codigo entre Android e iOS.

O painel de atitude 3D recebe `motion.roll_deg`, `motion.pitch_deg` e
`motion.yaw_deg`. O yaw do sensor movimenta o barco; arrastar horizontalmente
continua girando apenas a camera. Enquanto o firmware nao enviar `yaw_deg`, o
painel mostra `--` nesse campo sem inventar um rumo a partir do acelerometro.

## Android: APK para a equipe

A cada push ou pull request, o workflow `CI` gera dois artefatos:

- `telemetria-minerva-android-apk`: APK de teste instalavel diretamente;
- `telemetria-minerva-android-aab`: pacote destinado a Google Play.

Para baixar, abra **Actions > CI**, selecione a execucao concluida e use a secao **Artifacts**. Extraia o ZIP e transfira o APK para o celular. O Android pode solicitar autorizacao para instalar aplicativos provenientes do navegador ou do gerenciador de arquivos.

O APK atual serve para homologacao interna. Antes de publicar na Google Play, configure uma chave de assinatura de producao e guarde-a fora do repositorio, preferencialmente em GitHub Actions Secrets.

## iPhone: validacao e TestFlight

O job `ios` roda em macOS e compila o projeto com `--no-codesign`. O artefato `telemetria-minerva-ios-unsigned` comprova que o codigo compila para iPhone, mas **nao pode ser instalado diretamente** em um aparelho.

Para distribuir a equipe pelo TestFlight sera necessario:

1. Inscricao ativa no Apple Developer Program;
2. App registrado com o bundle ID `br.org.minervanautica.telemetriaMinervaApp`;
3. Certificado de distribuicao e provisioning profile;
4. Aplicativo criado no App Store Connect;
5. Segredos de assinatura configurados no GitHub Actions, ou upload realizado em um Mac pelo Xcode.

Depois que a equipe fornecer a conta Apple e definir quem administrara os certificados, o pipeline pode ser estendido para gerar o IPA assinado e envia-lo automaticamente ao TestFlight.

## URL da API

O celular precisa alcancar o backend por HTTPS. Em operacao no lago, use um dominio publico com TLS; enderecos como `localhost` e IPs privados do Raspberry Pi so funcionam quando o aparelho esta na mesma rede.

Nunca coloque tokens administrativos ou chaves privadas diretamente no codigo Flutter. Use autenticacao individual e configuracao por ambiente para producao.
