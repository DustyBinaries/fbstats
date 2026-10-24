unit FbApi;

{ Binding minimo da fbclient.dll (API "isc_*"), carregada dinamicamente.
  Cobre so o que a analise precisa:
    * Services API  -> equivalente ao gstat (DbStats)
    * DSQL          -> consultas somente leitura (colunas BLOB, fingerprints)
  O Delphi 7 gera 32 bits: a fbclient.dll tambem precisa ser de 32 bits. }

interface

uses
  Windows, SysUtils, Classes;

const
  STS_DATA_PAGES = $01;
  STS_HDR_PAGES = $04;
  STS_IDX_PAGES = $08;
  STS_RECORD_VERSIONS = $20;

type
  EFbError = class(Exception);

  TIscStatus = array[0..19] of Integer;
  PIscStatus = ^Integer;
  TFbHandle = Cardinal;
  PFbHandle = ^TFbHandle;

  { Devolve False para cancelar. }
  TFbBytesEvent = function(Total: Integer): Boolean of object;

  TXSqlVar = record
    SqlType: SmallInt;
    SqlScale: SmallInt;
    SqlSubType: SmallInt;
    SqlLen: SmallInt;
    SqlData: PChar;
    SqlInd: PSmallInt;
    SqlNameLength: SmallInt;
    SqlName: array[0..31] of Char;
    RelNameLength: SmallInt;
    RelName: array[0..31] of Char;
    OwnNameLength: SmallInt;
    OwnName: array[0..31] of Char;
    AliasNameLength: SmallInt;
    AliasName: array[0..31] of Char;
  end;
  PXSqlVar = ^TXSqlVar;

  TXSqlDaHeader = record
    Version: SmallInt;
    SqlDaId: array[0..7] of Char;
    SqlDaBc: Integer;
    SqlN: SmallInt;
    SqlD: SmallInt;
  end;
  PXSqlDa = ^TXSqlDaHeader;

  TFbClient = class;

  TFbQuery = class
  private
    FClient: TFbClient;
    FDb: PFbHandle;
    FTr: PFbHandle;
    FStmt: TFbHandle;
    FDa: PXSqlDa;
    FCount: Integer;
    FBufs: array of string;
    FInds: array of SmallInt;
    FOpen: Boolean;
    function Var_(I: Integer): PXSqlVar;
    procedure AllocDa(N: Integer);
  public
    constructor Create(AClient: TFbClient; ADb, ATr: PFbHandle);
    destructor Destroy; override;
    procedure Open(const Sql: string);
    { False quando acabaram as linhas. }
    function Next: Boolean;
    function IsNull(I: Integer): Boolean;
    { Bytes crus da coluna (VARCHAR sem o prefixo de tamanho). }
    function Raw(I: Integer): string;
    { Texto UTF-8 convertido para ANSI, sem espacos nas pontas. }
    function Text(I: Integer): string;
    property ColumnCount: Integer read FCount;
  end;

  TFbConn = class
  private
    FClient: TFbClient;
    FDb: TFbHandle;
    FTr: TFbHandle;
  public
    constructor Create(AClient: TFbClient; const DbPath, User, Password: string);
    destructor Destroy; override;
    { O TFbQuery pertence a quem chamou. }
    function Query(const Sql: string): TFbQuery;
  end;

  TFbClient = class
  private
    FLib: THandle;
    FAttach: function(St: PIscStatus; DbNameLen: SmallInt; DbName: PChar; var Db: TFbHandle; DpbLen: SmallInt; Dpb: PChar): Integer; stdcall;
    FDetach: function(St: PIscStatus; var Db: TFbHandle): Integer; stdcall;
    FStartTr: function(St: PIscStatus; var Tr: TFbHandle; Count: SmallInt; Db: PFbHandle; TpbLen: Integer; Tpb: PChar): Integer; cdecl;
    FRollback: function(St: PIscStatus; var Tr: TFbHandle): Integer; stdcall;
    FAllocStmt: function(St: PIscStatus; Db: PFbHandle; var Stmt: TFbHandle): Integer; stdcall;
    FPrepare: function(St: PIscStatus; Tr: PFbHandle; var Stmt: TFbHandle; Len: Word; Sql: PChar; Dialect: Word; Da: PXSqlDa): Integer; stdcall;
    FDescribe: function(St: PIscStatus; var Stmt: TFbHandle; Dialect: Word; Da: PXSqlDa): Integer; stdcall;
    FExecute: function(St: PIscStatus; Tr: PFbHandle; var Stmt: TFbHandle; Dialect: Word; Da: PXSqlDa): Integer; stdcall;
    FFetch: function(St: PIscStatus; var Stmt: TFbHandle; Dialect: Word; Da: PXSqlDa): Integer; stdcall;
    FFreeStmt: function(St: PIscStatus; var Stmt: TFbHandle; Option: Word): Integer; stdcall;
    FSvcAttach: function(St: PIscStatus; Len: Word; Name: PChar; var Svc: TFbHandle; SpbLen: Word; Spb: PChar): Integer; stdcall;
    FSvcDetach: function(St: PIscStatus; var Svc: TFbHandle): Integer; stdcall;
    FSvcStart: function(St: PIscStatus; var Svc: TFbHandle; Reserved: PFbHandle; SpbLen: Word; Spb: PChar): Integer; stdcall;
    FSvcQuery: function(St: PIscStatus; var Svc: TFbHandle; Reserved: PFbHandle; SendLen: Word; Send: PChar; ReqLen: Word; Req: PChar; BufLen: Word; Buf: PChar): Integer; stdcall;
    FInterpret: function(Buf: PChar; BufSize: Cardinal; var Status: PIscStatus): Integer; stdcall;
    function GetProc(const Name: string): Pointer;
    function DbStatsInner(var Svc: TFbHandle; const Path: string; Options: Cardinal; OnBytes: TFbBytesEvent): string;
  public
    constructor Create(const Path: string);
    destructor Destroy; override;
    function IsErr(const St: TIscStatus): Boolean;
    function Message(const St: TIscStatus): string;
    procedure Check(const St: TIscStatus);
    { Executa db_stats (gstat) e devolve o texto gerado. }
    function DbStats(const DbPath, User, Password: string; Options: Cardinal; OnBytes: TFbBytesEvent): string;
    function Connect(const DbPath, User, Password: string): TFbConn;
  end;

{ "host:caminho" -> Host, Path. Letra de unidade (C:\...) nao e host. }
procedure SplitHost(const DbPath: string; out Host, Path: string);
{ True se o arquivo e uma DLL PE de 32 bits. }
function IsDll32(const FileName: string): Boolean;
function Utf8Text(const S: string): string;

implementation

const
  DPB_VERSION1 = 1;
  DPB_USER_NAME = 28;
  DPB_PASSWORD = 29;
  DPB_LC_CTYPE = 48;
  TPB_VERSION3 = 3;
  TPB_WAIT = 6;
  TPB_READ = 8;
  TPB_READ_COMMITTED = 15;
  TPB_REC_VERSION = 17;
  SPB_VERSION = 2;
  SPB_CURRENT_VERSION = 2;
  ACTION_SVC_DB_STATS = 11;
  SPB_DBNAME = 106;
  SPB_OPTIONS = 108;
  INFO_SVC_TO_EOF = 63;
  DSQL_DROP = 2;
  SQL_VARYING = 448;
  SQL_TEXT = 452;
  LOAD_WITH_ALTERED_SEARCH_PATH = 8;
  SQLDA_HEADER = SizeOf(TXSqlDaHeader);

procedure SplitHost(const DbPath: string; out Host, Path: string);
var
  P: Integer;
begin
  Host := '';
  Path := DbPath;
  if Copy(DbPath, 1, 2) = '\\' then
    Exit;
  P := Pos(':', DbPath);
  if P > 2 then
  begin
    Host := Copy(DbPath, 1, P - 1);
    Path := Copy(DbPath, P + 1, MaxInt);
  end;
end;

function IsDll32(const FileName: string): Boolean;
var
  F: TFileStream;
  Off: Integer;
  Sig: Cardinal;
  Machine: Word;
begin
  Result := False;
  try
    F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      F.Position := $3C;
      if F.Read(Off, 4) <> 4 then Exit;
      F.Position := Off;
      if F.Read(Sig, 4) <> 4 then Exit;
      if Sig <> $00004550 then Exit;
      if F.Read(Machine, 2) <> 2 then Exit;
      Result := Machine = $014C;
    finally
      F.Free;
    end;
  except
    Result := False;
  end;
end;

function HasHighBit(const S: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    if S[I] >= #$80 then
    begin
      Result := True;
      Exit;
    end;
  Result := False;
end;

function Utf8Text(const S: string): string;
begin
  if HasHighBit(S) then
    Result := Utf8ToAnsi(S)
  else
    Result := S;
end;

function PStr(const S: string): PChar;
begin
  Result := PChar(S);
end;

{ TFbClient }

constructor TFbClient.Create(const Path: string);
begin
  inherited Create;
  if (Length(Path) > 1) and ((Path[2] = ':') or (Copy(Path, 1, 2) = '\\')) then
    FLib := LoadLibraryEx(PChar(Path), 0, LOAD_WITH_ALTERED_SEARCH_PATH)
  else
    FLib := LoadLibrary(PChar(Path));
  if FLib = 0 then
    raise EFbError.CreateFmt('%s: %s', [Path, SysErrorMessage(GetLastError)]);
  try
    @FAttach := GetProc('isc_attach_database');
    @FDetach := GetProc('isc_detach_database');
    @FStartTr := GetProc('isc_start_transaction');
    @FRollback := GetProc('isc_rollback_transaction');
    @FAllocStmt := GetProc('isc_dsql_allocate_statement');
    @FPrepare := GetProc('isc_dsql_prepare');
    @FDescribe := GetProc('isc_dsql_describe');
    @FExecute := GetProc('isc_dsql_execute');
    @FFetch := GetProc('isc_dsql_fetch');
    @FFreeStmt := GetProc('isc_dsql_free_statement');
    @FSvcAttach := GetProc('isc_service_attach');
    @FSvcDetach := GetProc('isc_service_detach');
    @FSvcStart := GetProc('isc_service_start');
    @FSvcQuery := GetProc('isc_service_query');
    @FInterpret := GetProc('fb_interpret');
  except
    FreeLibrary(FLib);
    FLib := 0;
    raise;
  end;
end;

destructor TFbClient.Destroy;
begin
  if FLib <> 0 then
    FreeLibrary(FLib);
  inherited;
end;

function TFbClient.GetProc(const Name: string): Pointer;
begin
  Result := GetProcAddress(FLib, PChar(Name));
  if Result = nil then
    raise EFbError.CreateFmt('%s nao encontrado na fbclient', [Name]);
end;

function TFbClient.IsErr(const St: TIscStatus): Boolean;
begin
  Result := (St[0] = 1) and (St[1] <> 0);
end;

function TFbClient.Message(const St: TIscStatus): string;
var
  Buf: array[0..1023] of Char;
  P: PIscStatus;
  N: Integer;
  Msg: string;
begin
  Result := '';
  P := @St[0];
  while True do
  begin
    N := FInterpret(@Buf[0], SizeOf(Buf), P);
    if N <= 0 then Break;
    SetString(Msg, Buf, N);
    if Result <> '' then Result := Result + ' / ';
    Result := Result + Utf8Text(Msg);
  end;
  if Result = '' then
    Result := Format('erro Firebird (codigo %d)', [St[1]]);
end;

procedure TFbClient.Check(const St: TIscStatus);
begin
  if IsErr(St) then
    raise EFbError.Create(Message(St));
end;

function TFbClient.DbStats(const DbPath, User, Password: string; Options: Cardinal; OnBytes: TFbBytesEvent): string;
var
  Host, Path, SvcName, Spb: string;
  St, St2: TIscStatus;
  Svc: TFbHandle;
begin
  SplitHost(DbPath, Host, Path);
  if Host <> '' then
    SvcName := Host + ':service_mgr'
  else
    SvcName := 'service_mgr';

  Spb := Chr(SPB_VERSION) + Chr(SPB_CURRENT_VERSION) +
    Chr(DPB_USER_NAME) + Chr(Length(User)) + User +
    Chr(DPB_PASSWORD) + Chr(Length(Password)) + Password;

  FillChar(St, SizeOf(St), 0);
  Svc := 0;
  FSvcAttach(@St[0], Length(SvcName), PChar(SvcName), Svc, Length(Spb), PChar(Spb));
  try
    Check(St);
  except
    on E: EFbError do
      raise EFbError.Create('service manager: ' + E.Message);
  end;
  try
    Result := DbStatsInner(Svc, Path, Options, OnBytes);
  finally
    FillChar(St2, SizeOf(St2), 0);
    FSvcDetach(@St2[0], Svc);
  end;
end;

function TFbClient.DbStatsInner(var Svc: TFbHandle; const Path: string; Options: Cardinal; OnBytes: TFbBytesEvent): string;
var
  St: TIscStatus;
  Start, Req: string;
  Buf: array[0..31999] of Char;
  Out_: TMemoryStream;
  I, L, Got: Integer;
  Truncated, NotReady, Done: Boolean;
begin
  FillChar(St, SizeOf(St), 0);
  Start := Chr(ACTION_SVC_DB_STATS) + Chr(SPB_DBNAME) +
    Chr(Length(Path) and $FF) + Chr((Length(Path) shr 8) and $FF) + Path +
    Chr(SPB_OPTIONS) +
    Chr(Options and $FF) + Chr((Options shr 8) and $FF) +
    Chr((Options shr 16) and $FF) + Chr((Options shr 24) and $FF);
  FSvcStart(@St[0], Svc, nil, Length(Start), PChar(Start));
  Check(St);

  Req := Chr(INFO_SVC_TO_EOF);
  Out_ := TMemoryStream.Create;
  try
    Done := False;
    while not Done do
    begin
      FillChar(Buf, SizeOf(Buf), 0);
      FSvcQuery(@St[0], Svc, nil, 0, nil, 1, PChar(Req), SizeOf(Buf), @Buf[0]);
      Check(St);

      I := 0;
      Got := 0;
      Truncated := False;
      NotReady := False;
      while I < SizeOf(Buf) do
      begin
        case Ord(Buf[I]) of
          INFO_SVC_TO_EOF:
            begin
              L := Ord(Buf[I + 1]) or (Ord(Buf[I + 2]) shl 8);
              Out_.Write(Buf[I + 3], L);
              Inc(Got, L);
              Inc(I, 3 + L);
              Continue;
            end;
          2: Truncated := True;
          3: raise EFbError.Create('erro no retorno do service manager');
          4: NotReady := True;
        end;
        Break; { isc_info_end ou qualquer outro codigo }
      end;
      if Assigned(OnBytes) then
        if not OnBytes(Out_.Size) then
          raise EFbError.Create('cancelado');
      if (Got = 0) and not Truncated then
      begin
        if NotReady then
        begin
          Sleep(50);
          Continue;
        end;
        Done := True;
      end;
    end;
    SetString(Result, PChar(Out_.Memory), Out_.Size);
  finally
    Out_.Free;
  end;
  Result := Utf8Text(Result);
end;

function TFbClient.Connect(const DbPath, User, Password: string): TFbConn;
begin
  Result := TFbConn.Create(Self, DbPath, User, Password);
end;

{ TFbConn }

constructor TFbConn.Create(AClient: TFbClient; const DbPath, User, Password: string);
var
  Dpb, Tpb: string;
  St, St2: TIscStatus;
begin
  inherited Create;
  FClient := AClient;
  Dpb := Chr(DPB_VERSION1) +
    Chr(DPB_USER_NAME) + Chr(Length(User)) + User +
    Chr(DPB_PASSWORD) + Chr(Length(Password)) + Password +
    Chr(DPB_LC_CTYPE) + Chr(4) + 'UTF8';
  FillChar(St, SizeOf(St), 0);
  FDb := 0;
  FClient.FAttach(@St[0], Length(DbPath), PChar(DbPath), FDb, Length(Dpb), PChar(Dpb));
  try
    FClient.Check(St);
  except
    on E: EFbError do
      raise EFbError.Create('conexao: ' + E.Message);
  end;

  { Read-only + read committed: nao segura o "oldest snapshot" em varreduras longas. }
  Tpb := Chr(TPB_VERSION3) + Chr(TPB_READ) + Chr(TPB_READ_COMMITTED) +
    Chr(TPB_REC_VERSION) + Chr(TPB_WAIT);
  FTr := 0;
  FClient.FStartTr(@St[0], FTr, 1, @FDb, Length(Tpb), PChar(Tpb));
  if FClient.IsErr(St) then
  begin
    FillChar(St2, SizeOf(St2), 0);
    FClient.FDetach(@St2[0], FDb);
    raise EFbError.Create('transacao: ' + FClient.Message(St));
  end;
end;

destructor TFbConn.Destroy;
var
  St: TIscStatus;
begin
  FillChar(St, SizeOf(St), 0);
  if FTr <> 0 then
    FClient.FRollback(@St[0], FTr);
  if FDb <> 0 then
    FClient.FDetach(@St[0], FDb);
  inherited;
end;

function TFbConn.Query(const Sql: string): TFbQuery;
begin
  Result := TFbQuery.Create(FClient, @FDb, @FTr);
  try
    Result.Open(Sql);
  except
    Result.Free;
    raise;
  end;
end;

{ TFbQuery }

constructor TFbQuery.Create(AClient: TFbClient; ADb, ATr: PFbHandle);
begin
  inherited Create;
  FClient := AClient;
  FDb := ADb;
  FTr := ATr;
end;

destructor TFbQuery.Destroy;
var
  St: TIscStatus;
begin
  if FStmt <> 0 then
  begin
    FillChar(St, SizeOf(St), 0);
    FClient.FFreeStmt(@St[0], FStmt, DSQL_DROP);
  end;
  if FDa <> nil then
    FreeMem(FDa);
  inherited;
end;

procedure TFbQuery.AllocDa(N: Integer);
begin
  if FDa <> nil then
    FreeMem(FDa);
  if N < 1 then N := 1;
  GetMem(FDa, SQLDA_HEADER + N * SizeOf(TXSqlVar));
  FillChar(FDa^, SQLDA_HEADER + N * SizeOf(TXSqlVar), 0);
  FDa^.Version := 1;
  FDa^.SqlN := N;
end;

function TFbQuery.Var_(I: Integer): PXSqlVar;
begin
  Result := PXSqlVar(Integer(FDa) + SQLDA_HEADER + I * SizeOf(TXSqlVar));
end;

procedure TFbQuery.Open(const Sql: string);
var
  St: TIscStatus;
  I, Size, Base: Integer;
  V: PXSqlVar;
  Q: string;
begin
  Q := AnsiToUtf8(Sql);
  FillChar(St, SizeOf(St), 0);
  FClient.FAllocStmt(@St[0], FDb, FStmt);
  FClient.Check(St);

  AllocDa(16);
  FClient.FPrepare(@St[0], FTr, FStmt, Length(Q), PChar(Q), 3, FDa);
  try
    FClient.Check(St);
  except
    on E: EFbError do
      raise EFbError.Create('prepare: ' + E.Message);
  end;

  FCount := FDa^.SqlD;
  if FCount > FDa^.SqlN then
  begin
    AllocDa(FCount);
    FClient.FDescribe(@St[0], FStmt, 3, FDa);
    FClient.Check(St);
  end;
  if FCount = 0 then
    raise EFbError.Create('a instrucao nao retorna linhas');

  SetLength(FBufs, FCount);
  SetLength(FInds, FCount);
  for I := 0 to FCount - 1 do
  begin
    V := Var_(I);
    Base := V^.SqlType and not 1;
    case Base of
      SQL_VARYING: Size := V^.SqlLen + 2;
      SQL_TEXT: Size := V^.SqlLen;
    else
      raise EFbError.CreateFmt('coluna %d com tipo SQL %d nao suportado (use CAST para VARCHAR)', [I + 1, Base]);
    end;
    if Size < 1 then Size := 1;
    SetLength(FBufs[I], Size);
    FillChar(FBufs[I][1], Size, 0);
    FInds[I] := 0;
    V^.SqlType := Base or 1;
    V^.SqlData := PChar(FBufs[I]);
    V^.SqlInd := @FInds[I];
  end;

  FClient.FExecute(@St[0], FTr, FStmt, 3, nil);
  try
    FClient.Check(St);
  except
    on E: EFbError do
      raise EFbError.Create('execute: ' + E.Message);
  end;
  FOpen := True;
end;

function TFbQuery.Next: Boolean;
var
  St: TIscStatus;
  Rc: Integer;
begin
  Result := False;
  if not FOpen then Exit;
  FillChar(St, SizeOf(St), 0);
  Rc := FClient.FFetch(@St[0], FStmt, 3, FDa);
  if Rc = 100 then
  begin
    FOpen := False;
    Exit;
  end;
  if Rc <> 0 then
    raise EFbError.Create('fetch: ' + FClient.Message(St));
  Result := True;
end;

function TFbQuery.IsNull(I: Integer): Boolean;
begin
  Result := FInds[I] = -1;
end;

function TFbQuery.Raw(I: Integer): string;
var
  L: Integer;
begin
  if FInds[I] = -1 then
  begin
    Result := '';
    Exit;
  end;
  if (Var_(I)^.SqlType and not 1) = SQL_VARYING then
  begin
    L := Ord(FBufs[I][1]) or (Ord(FBufs[I][2]) shl 8);
    Result := Copy(FBufs[I], 3, L);
  end
  else
    Result := FBufs[I];
end;

function TFbQuery.Text(I: Integer): string;
begin
  Result := Trim(Utf8Text(Raw(I)));
end;

end.
