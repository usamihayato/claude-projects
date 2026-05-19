# RAGの構成要素

## RAG とは（初学者向け）

**RAG（Retrieval-Augmented Generation）** とは、「**検索拡張生成**」とも呼ばれる手法です。

### わかりやすい例えで理解する

> **試験を受ける学生の例**
>
> - **LLM のみ（RAG なし）**: 試験前に暗記した知識だけで回答する。最新情報や専門知識が不足することも。
> - **RAG あり**: 試験中に参考書（= ドキュメント）を参照しながら回答する。正確な情報に基づいた回答が可能。

RAG は LLM の「知識の限界」を補うための仕組みです。

---

## RAG が解決する問題

| 問題 | 内容 | RAGによる解決 |
|------|------|---------------|
| 知識のカットオフ | LLMは学習データの日付以降の情報を知らない | 最新ドキュメントを検索して参照 |
| ハルシネーション | LLMが嘘の情報を自信満々に回答する | 根拠となる文書を明示できる |
| 社内固有知識 | 公開されていない社内情報をLLMは知らない | 社内ドキュメントをインデックス化 |
| コスト | 全情報をプロンプトに含めると高コスト | 必要な情報だけを検索して渡す |

---

## RAGの全体像

```mermaid
graph LR
    subgraph Indexing["インデックス作成フェーズ（事前処理）"]
        Doc["📄 ドキュメント<br/>(PDF/HTML/テキスト)"]
        Chunk["✂️ チャンキング<br/>(分割)"]
        Embed1["🔢 埋め込み<br/>(ベクトル化)"]
        VDB["🗄️ ベクトルDB<br/>への保存"]
        Doc --> Chunk --> Embed1 --> VDB
    end

    subgraph Retrieval["検索・生成フェーズ（実行時）"]
        Query["❓ ユーザーの質問"]
        Embed2["🔢 質問を<br/>ベクトル化"]
        Search["🔍 類似検索<br/>(コサイン類似度)"]
        Context["📋 関連文書<br/>の取得"]
        Prompt["📝 プロンプト<br/>構築"]
        LLM["🤖 LLM<br/>回答生成"]
        Answer["💬 回答"]

        Query --> Embed2 --> Search --> Context --> Prompt --> LLM --> Answer
        VDB -.->|類似チャンクを返す| Search
    end

    style Indexing fill:#e8f4fd
    style Retrieval fill:#fff3e8
```

---

## 構成要素の詳細

### 1. ドキュメントローダー（Document Loader）

ドキュメントを読み込む処理です。

```mermaid
graph TD
    PDF["📄 PDF"] --> Loader
    HTML["🌐 HTML/Web"] --> Loader
    Word["📝 Word/Excel"] --> Loader
    Text["📃 テキスト"] --> Loader
    DB["🗄️ データベース"] --> Loader
    Loader["Document Loader<br/>（テキスト抽出）"] --> RawText["📜 生テキスト"]
```

**Snowflake でのアプローチ**:
- ステージにファイルをアップロード
- `PARSE_DOCUMENT` 関数でテキスト抽出
- テーブルに格納してからチャンキング

---

### 2. チャンキング（Chunking）

長いドキュメントを適切なサイズに分割します。

```mermaid
graph TB
    Doc["長いドキュメント（例: 10,000文字）"]

    Doc --> C1["チャンク1<br/>文字1〜500"]
    Doc --> C2["チャンク2<br/>文字400〜900<br/>（オーバーラップ）"]
    Doc --> C3["チャンク3<br/>文字800〜1300"]
    Doc --> C4["チャンク4<br/>..."]

    note["💡 オーバーラップ（重複）を設けることで<br/>文脈の断絶を防ぐ"]
```

**チャンクサイズの目安**:

| 用途 | チャンクサイズ | オーバーラップ |
|------|---------------|----------------|
| 短い質問応答 | 200〜500文字 | 50〜100文字 |
| 詳細な説明が必要 | 500〜1000文字 | 100〜200文字 |
| 長文要約 | 1000〜2000文字 | 200〜400文字 |

---

### 3. 埋め込みモデル（Embedding Model）

テキストを数値ベクトルに変換します。意味的に近いテキストは、ベクトル空間でも近い位置に配置されます。

```mermaid
graph LR
    T1["'Snowflakeはデータ<br/>ウェアハウスです'"] --> E1["[0.23, -0.41, 0.67, ...]"]
    T2["'クラウドDWHの<br/>代表例がSnowflake'"] --> E2["[0.25, -0.39, 0.65, ...]"]
    T3["'今日の天気は<br/>晴れです'"] --> E3["[-0.82, 0.11, -0.34, ...]"]

    E1 -.->|類似度: 0.97| E2
    E1 -.->|類似度: 0.12| E3
```

**Snowflake Cortex の埋め込み関数**:
```sql
-- 768次元ベクトル（軽量・高速）
SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768(
    'snowflake-arctic-embed-m',
    'テキスト内容'
) AS vector;

-- 1024次元ベクトル（高精度）
SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_1024(
    'voyage-multilingual-2',  -- 多言語対応
    'テキスト内容'
) AS vector;
```

---

### 4. ベクトルデータベース（Vector Database）

ベクトルを保存し、類似ベクトルを高速に検索するためのデータストアです。

```mermaid
graph TB
    subgraph VectorDB["ベクトルDB（Snowflake VECTOR型）"]
        Row1["ID:1 | チャンク: '...テキスト1...' | Vector: [0.1, 0.2, ...]"]
        Row2["ID:2 | チャンク: '...テキスト2...' | Vector: [0.5, -0.1, ...]"]
        Row3["ID:3 | チャンク: '...テキスト3...' | Vector: [-0.3, 0.8, ...]"]
    end

    Query["質問ベクトル: [0.09, 0.21, ...]"]
    Query -->|コサイン類似度で検索| Row1
    Row1 -->|最も近い| Result["検索結果（上位K件）"]
```

**Snowflake でのベクトルデータ型**:
```sql
-- VECTOR型の定義
CREATE TABLE document_chunks (
    id          NUMBER AUTOINCREMENT PRIMARY KEY,
    doc_name    VARCHAR,
    chunk_text  VARCHAR,
    chunk_vec   VECTOR(FLOAT, 768)  -- 768次元ベクトル
);
```

---

### 5. リトリーバー（Retriever）

クエリに関連するチャンクを検索する処理です。

```mermaid
graph TB
    subgraph SearchTypes["検索手法"]
        Dense["Dense Search<br/>（ベクトル類似度）<br/>意味的な一致"]
        Sparse["Sparse Search<br/>（BM25/キーワード）<br/>語彙的な一致"]
        Hybrid["Hybrid Search<br/>（Dense + Sparse）<br/>両方を組み合わせ"]
    end

    Query["ユーザーの質問"] --> Dense
    Query --> Sparse
    Dense --> Hybrid
    Sparse --> Hybrid
    Hybrid --> Results["関連チャンク TOP-K"]
```

**Snowflake でのベクトル検索**:
```sql
-- コサイン類似度による検索（VECTOR_COSINE_SIMILARITY）
SELECT
    chunk_text,
    VECTOR_COSINE_SIMILARITY(chunk_vec, :query_vec) AS similarity
FROM document_chunks
ORDER BY similarity DESC
LIMIT 5;
```

---

### 6. プロンプトエンジニアリング（Prompt Engineering）

検索したコンテキストと質問を組み合わせて、LLM への指示を構築します。

```
┌─────────────────────────────────────────────────┐
│ システムプロンプト                                │
│ "あなたは○○の専門家です。以下の文脈のみを使って │
│  質問に答えてください。わからない場合は          │
│  'わかりません'と答えてください。"               │
├─────────────────────────────────────────────────┤
│ 検索されたコンテキスト（文脈）                   │
│ "文書1: ...チャンク1の内容..."                   │
│ "文書2: ...チャンク2の内容..."                   │
│ "文書3: ...チャンク3の内容..."                   │
├─────────────────────────────────────────────────┤
│ ユーザーの質問                                   │
│ "Snowflake Cortexの料金体系を教えてください"     │
└─────────────────────────────────────────────────┘
```

---

### 7. LLM（大規模言語モデル）

コンテキストを理解し、回答を生成します。

```mermaid
sequenceDiagram
    participant U as ユーザー
    participant R as リトリーバー
    participant L as LLM

    U->>R: 質問送信
    R->>R: 質問をベクトル化
    R->>R: 類似文書を検索（Top-K）
    R->>L: プロンプト（文脈+質問）を送信
    L->>L: 文脈を理解して回答生成
    L->>U: 回答を返す
```

---

## RAG の品質を決める重要因子

```mermaid
graph TD
    Quality["RAGの品質"]

    Quality --> Chunking["チャンキング戦略<br/>・サイズ<br/>・オーバーラップ<br/>・分割方法"]
    Quality --> Embedding["埋め込みモデルの選択<br/>・多言語対応<br/>・ドメイン特化<br/>・次元数"]
    Quality --> Retrieval["検索精度<br/>・類似度閾値<br/>・返却件数(K)<br/>・ハイブリッド検索"]
    Quality --> Prompt["プロンプト設計<br/>・指示の明確さ<br/>・出力フォーマット<br/>・ロール設定"]
    Quality --> LLMChoice["LLMの選択<br/>・モデルサイズ<br/>・コンテキスト長<br/>・ドメイン知識"]
```

---

## 次のステップ

- [Cortexを使ったRAGサンプル](./04_cortex_rag_sample.md) - 実際にコードを書いてみる
- [デモアプリ作成](./05_demo_app.md) - Streamlit でアプリを構築する
