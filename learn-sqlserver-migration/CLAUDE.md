# CLAUDE.md

## 役割

私はシステムエンジニアです。自社の SQL Server をオンプレミスからクラウド（Azure）へ移行するための事前調査を担当しています。

## 目標

1. **ノックアウト要件の洗い出しと解消策の整理**
   - 移行を阻む技術的制約を事前に特定し、対処方針を確立する
2. **最適な移行先の選定**
   - Azure SQL Database / Azure SQL Managed Instance / SQL Server on Azure VM を比較し、自社要件に合った構成を選ぶ
3. **移行ツール（ADMS: Azure Database Migration Service）の活用方針を確立**
4. **Windows Server EOL 依存からの脱却**
   - オンプレ SQL Server × Windows Server の組み合わせによる EOL タスクをゼロにする
5. **総コストの削減**
   - Azure Hybrid Benefit・Reserved Instances・PaaS 化によるコスト最適化を検討する

## 制約

- 日本語で回答すること
- Microsoft 公式ドキュメントをベースに情報を整理すること
- 特定の SQL Server バージョンや機能に依存する箇所は明記すること

## 参考

- [Azure SQL 移行ガイド](https://learn.microsoft.com/ja-jp/data-migration/sql-server/)
- [Azure Database Migration Service ドキュメント](https://learn.microsoft.com/ja-jp/azure/dms/)
- [Azure SQL Managed Instance の機能比較](https://learn.microsoft.com/ja-jp/azure/azure-sql/managed-instance/transact-sql-tsql-differences-sql-server)
