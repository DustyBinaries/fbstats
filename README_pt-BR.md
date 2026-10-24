# Firebird · Estatísticas de tamanho (Delphi 7 + Borion)

Ferramenta de estatísticas de tamanho do Firebird escrita em Delphi 7 usando o [framework Borion](https://github.com/DustyBinaries/Borion/).
Interface web (`web\`) e análise: Services API (gstat), censo de páginas do `.fdb`,
medição de colunas BLOB, duplicação entre BLOBs e observações.

## Compilar

    set DELPHI=C:\Program Files (x86)\Borland\Delphi7
    build.bat

Gera `fbstats.exe` (a interface vai embutida). Ou `borion dev` para recarregar a interface ao salvar.

## Usar

    fbstats.exe                      # abre a janela
    fbstats.exe C:\dados\banco.fdb   # abre e analisa a base ao iniciar
    fbstats.exe --selftest C:\dados\banco.fdb [usuario] [senha] [--no-census] [--no-blobs] [--dup]
                                     # sem janela; JSON em stdout, progresso em stderr

O exe é **32 bits** (Delphi 7): precisa da `fbclient.dll` de **32 bits** (ao lado do .exe, no
`WOW64` do Firebird ou em `C:\Windows\SysWOW64`). A busca ignora DLLs de 64 bits.
Como o exe é GUI, para capturar o `--selftest` em arquivo use `Start-Process -Wait -RedirectStandardOutput`.

## Estrutura

- `FbApi.pas`       binding da fbclient (Services API + DSQL), carregado dinamicamente
- `FbAnalysis.pas`  cabeçalho, censo, parse do gstat, BLOBs, duplicação, observações, JSON do relatório
- `fbstats.dpr` comandos do Borion (`analyze` em thread, `cancel_analysis`, `default_fbclient`, `startup_db`, `save_text`)
- `web\`            interface (HTML/CSS/JS), usando `window.borion`
