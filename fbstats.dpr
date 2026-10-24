program fbstats;

// Firebird · Estatísticas de tamanho: port do fbstats (Tauri/Rust) para Delphi 7 + Borion.
// A interface fica em web\ (HTML, CSS e JS); a lógica nativa, em FbApi.pas e FbAnalysis.pas.
//   fbstats.exe                      abre a janela
//   fbstats.exe C:\dados\banco.fdb   abre e analisa a base ao iniciar
//   fbstats.exe --selftest <base> [usuario] [senha] [--no-census] [--no-blobs] [--dup]
//                                    sem janela; imprime o relatório em JSON (stdout)

uses
  Windows, SysUtils, Classes, Jsons, EncdDecd, Borion, BorionIpc, BorionDialog, BorionWindow,
  FbApi in 'FbApi.pas', FbAnalysis in 'FbAnalysis.pas';

{$R *.res}
{$R web.res}  // a pasta web\, empacotada pelo build.bat

type
  { O analyze roda numa thread: a janela continua respondendo e o progresso sai por evento. }
  TAnalysisThread = class(TThread)
  private
    FCall: TBorionCall;
    FParams: TAnalysisParams;
    procedure Progress(const Stage: string; Pct: Double; const Msg: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ACall: TBorionCall; const AParams: TAnalysisParams);
  end;

var
  Running: Boolean = False;

constructor TAnalysisThread.Create(ACall: TBorionCall; const AParams: TAnalysisParams);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FCall := ACall;
  FParams := AParams;
end;

procedure TAnalysisThread.Progress(const Stage: string; Pct: Double; const Msg: string);
var
  O: TJsonObject;
begin
  if FCall.Ipc = nil then Exit;
  O := TJsonObject.Create;
  try
    O.Put('stage', Stage);
    if Pct >= 0 then O.Put('pct', Pct) else O.Put('pct', null);
    O.Put('msg', Msg);
    FCall.Ipc.Emit('progress', O);
  finally
    O.Free;
  end;
end;

procedure TAnalysisThread.Execute;
var
  R: TReport;
begin
  try
    try
      R := RunAnalysis(FParams, Progress);
      try
        FillReportJson(R, FCall.Result.AsObject);
      finally
        R.Free;
      end;
      FCall.Resolve;
    except
      on E: ECancelled do
        FCall.Reject('cancelado', 'CANCELLED');
      on E: Exception do
        FCall.Reject(E.Message, 'ANALYSIS');
    end;
  finally
    Running := False;
  end;
end;

function JsonStr(Obj: TJsonObject; const Name: string; const Default: string = ''): string;
var
  I: Integer;
begin
  Result := Default;
  I := Obj.Find(Name);
  if (I >= 0) and not (Obj.Items[I].Value.ValueType in [jvNone, jvNull]) then
    Result := Obj.Items[I].Value.AsString;
end;

function JsonBool(Obj: TJsonObject; const Name: string; Default: Boolean): Boolean;
var
  I: Integer;
begin
  Result := Default;
  I := Obj.Find(Name);
  if (I >= 0) and not (Obj.Items[I].Value.ValueType in [jvNone, jvNull]) then
    Result := Obj.Items[I].Value.AsBoolean;
end;

function JsonNum(Obj: TJsonObject; const Name: string; Default: Double): Double;
var
  I: Integer;
begin
  Result := Default;
  I := Obj.Find(Name);
  if (I >= 0) and not (Obj.Items[I].Value.ValueType in [jvNone, jvNull]) then
    Result := Obj.Items[I].Value.AsNumber;
end;

procedure Analyze(Call: TBorionCall);
var
  V: TJsonValue;
  O: TJsonObject;
  P: TAnalysisParams;
begin
  if Running then
    raise EBorionError.Create('BUSY', 'já existe uma análise em andamento.');
  V := Call.Arg('params');
  if (V = nil) or (V.ValueType <> jvObject) then
    raise EBorionError.Create('BAD_ARGS', 'params ausente.');
  O := V.AsObject;
  FillChar(P, SizeOf(P), 0);
  P.Database := JsonStr(O, 'database');
  P.User := JsonStr(O, 'user', 'SYSDBA');
  P.Password := JsonStr(O, 'password');
  P.FbClient := JsonStr(O, 'fbclient');
  P.Census := JsonBool(O, 'census', True);
  P.Blobs := JsonBool(O, 'blobs', True);
  P.DupScan := JsonBool(O, 'dupScan', False);
  P.DupTop := Trunc(JsonNum(O, 'dupTop', 0));
  P.DupMinMb := JsonNum(O, 'dupMinMb', -1);
  P.DupOffset := Trunc(JsonNum(O, 'dupOffset', 0));
  P.DupLength := Trunc(JsonNum(O, 'dupLength', 0));
  P.HostFile := JsonStr(O, 'hostFile');

  Running := True;
  Call.Defer;
  TAnalysisThread.Create(Call, P).Resume;
end;

procedure CancelAnalysis(Call: TBorionCall);
begin
  AnalysisCancel := True;
end;

procedure DefaultFbClient(Call: TBorionCall);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    CandidateFbClients(L);
    if L.Count > 0 then
      Call.Result.AsString := L[0]
    else
      Call.Result.AsString := '';
  finally
    L.Free;
  end;
end;

{ Base passada na linha de comando (fbstats.exe caminho.fdb): abre e analisa ao iniciar. }
procedure StartupDb(Call: TBorionCall);
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if Copy(ParamStr(I), 1, 2) <> '--' then
    begin
      Call.Result.AsString := ParamStr(I);
      Exit;
    end;
end;

{ Grava o CSV: o JS manda os bytes UTF-8 em base64; o BOM é acrescentado aqui. }
procedure SaveText(Call: TBorionCall);
const
  Bom = #$EF#$BB#$BF;
var
  Path, Data: string;
  F: TFileStream;
begin
  Path := Call.ArgStr('path');
  if Path = '' then
    raise EBorionError.Create('BAD_ARGS', 'path ausente.');
  Data := Bom + DecodeString(Call.ArgStr('b64'));
  try
    F := TFileStream.Create(Path, fmCreate);
  except
    on E: Exception do
      raise EBorionError.Create('IO', Path + ': ' + E.Message);
  end;
  try
    F.WriteBuffer(Data[1], Length(Data));
  finally
    F.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ --selftest                                                          }
{ ------------------------------------------------------------------ }

type
  TSelfTest = class
    procedure Progress(const Stage: string; Pct: Double; const Msg: string);
  end;

procedure WriteStd(Handle: DWORD; const S: string);
var
  H: THandle;
  N: Cardinal;
begin
  H := GetStdHandle(Handle);
  if (H = 0) or (H = INVALID_HANDLE_VALUE) then Exit;
  if S <> '' then
    WriteFile(H, S[1], Length(S), N, nil);
end;

procedure TSelfTest.Progress(const Stage: string; Pct: Double; const Msg: string);
begin
  WriteStd(STD_ERROR_HANDLE, '[' + Stage + '] ' + Msg + #13#10);
end;

function HasFlag(const F: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 2 to ParamCount do
    if ParamStr(I) = F then Result := True;
end;

procedure SelfTest;
var
  P: TAnalysisParams;
  Pos_: TStringList;
  I: Integer;
  R: TReport;
  O: TJsonObject;
  T: TSelfTest;
  Json: string;
begin
  Pos_ := TStringList.Create;
  try
    for I := 2 to ParamCount do
      if Copy(ParamStr(I), 1, 2) <> '--' then
        Pos_.Add(ParamStr(I));
    FillChar(P, SizeOf(P), 0);
    if Pos_.Count > 0 then P.Database := Pos_[0];
    P.User := 'SYSDBA';
    if Pos_.Count > 1 then P.User := Pos_[1];
    P.Password := 'masterkey';
    if Pos_.Count > 2 then P.Password := Pos_[2];
    P.Census := not HasFlag('--no-census');
    P.Blobs := not HasFlag('--no-blobs');
    P.DupScan := HasFlag('--dup');
    P.DupMinMb := 0;
  finally
    Pos_.Free;
  end;
  T := TSelfTest.Create;
  try
    try
      R := RunAnalysis(P, T.Progress);
      try
        O := TJsonObject.Create;
        try
          FillReportJson(R, O);
          Json := O.Stringify;
        finally
          O.Free;
        end;
      finally
        R.Free;
      end;
      WriteStd(STD_OUTPUT_HANDLE, Json + #13#10);
    except
      on E: Exception do
      begin
        WriteStd(STD_ERROR_HANDLE, 'ERRO: ' + E.Message + #13#10);
        ExitCode := 1;
      end;
    end;
  finally
    T.Free;
  end;
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--selftest') then
  begin
    SelfTest;
    Exit;
  end;
  TBorionBuilder.Create  // título e janela: app.json
    .Plugin(TBorionDialogPlugin.Create)  // diálogos nativos: @borion/api/dialog
    .Plugin(TBorionWindowPlugin.Create)  // barra de título em HTML: arrastar, minimizar, maximizar, fechar
    .Command('analyze', Analyze)
    .Command('cancel_analysis', CancelAnalysis)
    .Command('default_fbclient', DefaultFbClient)
    .Command('startup_db', StartupDb)
    .Command('save_text', SaveText)
    .Run;
end.
