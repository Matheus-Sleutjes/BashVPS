Aja como um Arquiteto de Software sênior especialista em .NET 8+ e Angular (v20+ utilizando Standalone Components e Signals). Preciso que você gere a estrutura de pastas e o código base para um MVP de um sistema de vitrine e vendas com controle de garantias. Para fins de MVP rápido, não haverá autenticação ou controle de login (todas as rotas e endpoints são públicos por enquanto).

O ecossistema deve seguir rigorosamente os princípios do SOLID, Injeção de Dependência (DIP) e uma Arquitetura em Camadas desacoplada. 

A solução do projeto deve seguir exatamente esta estrutura de nomenclatura de projetos:
- GestorVitrine.Domain (Modelos ricos, enums, DTOs de entrada/saída)
- GestorVitrine.Infrastructure (DbContext, mapeamentos Fluent API, implementações de repositório, contratos de repositório)
- GestorVitrine.Application ( contratos e implementações de Serviços de Aplicação)
- GestorVitrine.API (Controladores HTTP e configuração da Injeção de Dependência)
- GestorVitrine.Front (Aplicação Angular)

Para a nomenclatura das classes entre as camadas, siga estritamente o seguinte padrão (usando a entidade Exemplo como referência):
- Entidade de Domínio: Exemplo.cs (na pasta entities na camada .Domain)
- Interface do Repositório: IExemploRepository.cs (na pasta contracts na camada .Infrastructure)
- Implementação do Repositório: ExemploRepository.cs (na pasta repositories na camada .Infrastructure)
- Interface do Serviço de Aplicação: IExemploService.cs (na pasta contracts na camada .Application)
- Implementação do Serviço de Aplicação: ExemploService.cs (na pasta services na camada .Application)
- Data Transfer Objects: CriarExemploDto.cs, ExemploResumoDto.cs (na pasta DTOs na camada .Domain)
- Controlador API: ExemploController.cs (na camada .API)

---

### 1. REQUISITOS DO BACKEND (.NET 8+)

#### GestorVitrine.Domain:
Crie as seguintes entidades puras e seus enums:
- Cliente (ClienteId, Nome, Cpf, Email, Telefone)
- Produto (ProdutoId, Nome, Descricao, Preco, QuantidadeEstoque, ImagemUrl)
- Pedido (PedidoId, ClienteId, DataPedido, ValorTotal, ICollection<ItemPedido>)
- ItemPedido (ItemPedidoId, PedidoId, ProdutoId, Quantidade, PrecoUnitario, Garantia Garantia)
- Garantia (GarantiaId, ItemPedidoId, ProdutoId, DataInicio, DataFim, StatusGarantia)
- Enum StatusGarantia (Ativa, Inativa, Acionada)
Defina as interfaces de repositório assíncronas para cada entidade (`IClienteRepository`, `IProdutoRepository`, `IPedidoRepository`, `IGarantiaRepository`).

#### GestorVitrine.Infrastructure:
- Implemente o `GestorVitrineDbContext` usando Entity Framework Core. Configure os relacionamentos e chaves via Fluent API.
- Implemente os repositórios correspondentes injetando o `DbContext`. Use `.AsNoTracking()` nos métodos de leitura voltados para consultas e paginação.

#### GestorVitrine.Application:
- Crie os DTOs necessários para as operações (Ex: `CriarPedidoDto`, `ProdutoVitrineDto`, `GarantiaResumoDto`).
- Implemente os Serviços de Aplicação (`ClienteService`, `ProdutoService`, `PedidoService`, `GarantiaService`).
- **Regra de Negócio com SRP (Princípio de Responsabilidade Única):** No método `CriarPedidoAsync` do `PedidoService`, o sistema deve: receber os dados, abater a quantidade do estoque dos produtos, persistir o Pedido/Itens e gerar AUTOMATICAMENTE um registro de Garantia com validade de 1 ano para cada item contido no pedido.

#### GestorVitrine.API:
Configure a injeção de dependência no `Program.cs` relacionando as interfaces às suas respectivas implementações. Crie os controladores injetando os Serviços de Aplicação:
- `ProdutoController`: GET público paginado para a vitrine, GET por ID para detalhes, e CRUD administrativo (recebendo dados via `FromForm` para simular o upload de imagens).
- `ClienteController`: CRUD completo para a gestão de clientes.
- `PedidoController`: POST para realizar a venda e GET para o histórico.
- `GarantiaController`: GET para listagem de painel e PUT/PATCH para atualizar o status da garantia.
- `DashboardController`: GET para retornar um DTO com indicadores (Total faturado, total de pedidos, total de produtos em estoque e quantidade de garantias ativas).

---

### 2. REQUISITOS DO FRONTEND (GestorVitrine.Front)

O projeto frontend deve respeitar estritamente a árvore de diretórios atual do sistema. O Angular deve utilizar standalone components configurados via `app.routes.ts` e `app.config.ts`, e gerenciar o estado e reatividade com Signals onde for pertinente.

Mapeie e gere os arquivos considerando a seguinte estrutura de pastas existente:
- src/app/models/          -> Interfaces e Types TypeScript (Ex: produto.model.ts, pedido.model.ts).
- src/app/services/        -> Serviços Http para consumir a Web API (Ex: produto.service.ts, pedido.service.ts).
- src/app/pages/           -> Componentes que representam as telas/páginas completas.
- src/app/components/      -> Componentes menores, reutilizáveis e utilitários.
- src/app/interceptors/    -> Interceptadores Http globais.

Gere os arquivos abaixo preenchendo as seguintes views dentro de `src/app/pages/`:

1. Vitrine (Pública): Grid com paginação exibindo cards de produtos contendo foto (ImagemUrl), nome, preço e o botão "Ver Detalhes".
2. Detalhe do Produto (Pública): Tela com informações expandidas do produto e um botão para realizar a compra (simulando a abertura de um fluxo simplificado de checkout).
3. Painel Administrativo (Layout com Menu Lateral de Navegação):
   - Dashboard: Cards visuais exibindo as métricas consumidas do DashboardController.
   - Estoque (CRUD Produto): Tabela de listagem com ações de Criar/Editar (formulário com input de arquivo para imagem) e Excluir.
   - Clientes: Tela de gerenciamento com formulário e tabela para o CRUD de clientes.
   - Pedidos: Lista histórica dos pedidos realizados, mostrando cliente, data e valor total.
   - Garantias: Tabela geral exibindo o número do pedido, o produto e um campo select (dropdown) para alterar o StatusGarantia em tempo real.

---

### REQUISITOS DE SAÍDA:
- Apresente a árvore de diretórios sugerida para toda a solução organizada por camadas.
- Forneça o código completo das Entidades do `GestorVitrine.Domain`.
- Forneça a implementação detalhada do caso de uso de criação de Pedido + Garantia no `PedidoService`.
- Forneça a configuração de rotas do Angular (`app.routes.ts`) evidenciando a separação das rotas públicas da vitrine e das rotas do painel administrativo.
- Escreva um código limpo, tipado, modular e pronto para compilar.