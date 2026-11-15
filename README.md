# Tron Racing

App de iPhone que espelha a tela do celular (com o **Waze**) no painel TFT da **Zontes**
(painéis 2025+, que mostram um QR com `ID:CARBIT…` embaixo). O painel original da moto continua
a um toque do botão do guidão.

Versão 0.1: primeira versão para testar na moto. **Ainda não foi testada num painel real.**

## Como funciona

1. **Bluetooth:** o app acha o painel (nome `EC` + 8 letras, serviço `B360`) e passa para ele o nome e a senha do seu
   **Acesso Pessoal**.
2. **Wi-Fi:** o painel entra no Acesso Pessoal do iPhone (rede 172.20.10.x), o app "acorda" o painel e
   ele abre os canais de controle e de vídeo.
3. **Vídeo:** a *transmissão de tela* do iOS (extensão ReplayKit) capta a tela inteira, gira, reduz
   para 800×480, codifica em H.264 no chip de vídeo do iPhone e o app envia ao painel.
4. Sem transmissão ativa, o painel mostra uma tela de espera neon do Tron Racing.

O protocolo do painel veio do projeto aberto [MotoNav](https://github.com/EpaminondasDiniz/motonav)
(Android, licença MIT), que por sua vez aprendeu a parte de Bluetooth com o
[ZC-Panel](https://github.com/luan441-s/ZC-Panel).

## Compilar (sem Mac): GitHub Actions

1. Crie um repositório no GitHub (pode ser privado) e envie todos os arquivos desta pasta, incluindo
   a pasta oculta `.github`.
2. Abra a aba **Actions**. A compilação "Compilar IPA" roda sozinha a cada envio (ou toque em
   *Run workflow*).
3. Quando terminar (bolinha verde, uns 5 min), abra a execução e baixe o artefato
   **TronRacing-ipa**. Dentro do zip está o `TronRacing.ipa`, **sem assinatura**.
4. Se der erro, baixe o artefato **log-da-compilacao** e me mande.

## Instalar no iPhone (3uTools)

1. Ligue o iPhone no PC com o 3uTools aberto.
2. **Toolbox > IPA Signature**: adicione o `TronRacing.ipa`, escolha **Apple ID** e entre com o seu
   (gratuito serve) e assine.
3. Instale o IPA assinado (Apps > Import & Install).
4. No iPhone: **Ajustes > Geral > VPN e Gerenciamento de Dispositivo**, toque no seu Apple ID e em
   **Confiar**.
5. Com Apple ID gratuito, a assinatura vale **7 dias**: depois é só assinar e instalar de novo.

Se o 3uTools não assinar a extensão de transmissão (o botão ESPELHAR não mostra "Tron Racing"), use o
**Sideloadly**, que assina extensões direitinho.

## Primeiro uso

1. **Acesso Pessoal:** ligue *Permitir Outros Acessarem* e *Maximizar Compatibilidade*. No app,
   preencha o nome da rede (é o nome do iPhone, em Ajustes > Geral > Sobre) e a senha.
2. Ligue a moto e abra no painel a tela de conexão do celular. Feche o app Carbit (ele conecta primeiro).
3. No app, toque em **LER QR DO PAINEL** e depois em **CONECTAR**. Aceite Bluetooth, **Rede Local**
   e Localização (*Ao Usar o App*).
4. Enquanto conecta, deixe aberta a tela do Acesso Pessoal (em Ajustes) até o painel entrar.
5. Quando aparecer **NO AR**, toque em **ESPELHAR TELA > Iniciar Transmissão**, abra o Waze e deite o celular.
6. **Painel original:** botão de modo no guidão. Aperte de novo para voltar ao Waze.

Se algo falhar: **DIÁRIO DA CONEXÃO > compartilhar**, e mande o texto.

## Limites do iPhone

- Só painéis 2025+ (Bluetooth + hotspot). Os anteriores usam Wi-Fi Direct, que o iPhone não tem.
- A transmissão para quando o iPhone bloqueia a tela: deixe a tela ligada (o Waze já faz isso navegando).
- O app fica vivo em segundo plano pela localização (pílula azul no topo). Não feche o app na
  multitarefa durante a viagem.
- O Acesso Pessoal precisa do plano de dados com compartilhamento ativo, mas o painel não gasta seus dados.

## Arquivos

| Pasta | O que tem |
|---|---|
| `App/` | App principal: tela (SwiftUI), Bluetooth (`BleLink`), conexão com o painel (`DashLink`, `RvServer`), protocolo (`Protocol.swift`) |
| `Broadcast/` | Extensão de transmissão de tela (`SampleHandler`) |
| `Shared/` | Codificador H.264, redimensionamento, sockets e a conversa extensão ↔ app |
| `project.yml` | Projeto para o XcodeGen gerar o `.xcodeproj` |

Projeto pessoal, sem relação com a Zontes, a Carbit ou a Disney. Não mexa no celular pilotando.
