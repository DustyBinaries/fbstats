unit FbAnalysis;

{ Port do analysis.rs (e do fb_dbsize.py): cabecalho, censo de paginas, gstat -a -r,
  medicao de BLOBs e deteccao de duplicacao. Tudo somente leitura e direto pela
  fbclient.dll (de 32 bits, porque o Delphi 7 gera 32 bits). }

interface

uses
  Windows, SysUtils, Classes, Contnrs, Jsons, FbApi;

type
  EAnalysis = class(Exception);
  ECancelled = class(EAnalysis);

  { Pct < 0: progresso indeterminado. }
  TProgressEvent = procedure(const Stage: string; Pct: Double; const Msg: string) of object;

  TAnalysisParams = record
    Database: string;
    User: string;
    Password: string;
    FbClient: string;
    Census: Boolean;
    Blobs: Boolean;
    DupScan: Boolean;
    DupTop: Integer;       { <= 0: padrao (6) }
    DupMinMb: Double;      { < 0: padrao (64) }
    DupOffset: Integer;    { <= 0: padrao (200) }
    DupLength: Integer;    { <= 0: padrao (24) }
    HostFile: string;
  end;

  TCensusRow = class
  public
    Key, Label_: string;
    Pages, Bytes: Int64;
    Pct: Double;
  end;

  TTable = class
  public
    Name: string;
    Records, Versions, MaxVersions: Int64;
    AvgRecord: Double;
    DataPages, Fill, IndexCount, IndexPages, BlobPages: Int64;
    GstatBlobBytes, BlobPayload: Int64;
    DataBytes, IndexBytes, BlobBytes, TotalBytes: Int64;
  end;

  TIndex = class
  public
    Table, Name: string;
    Depth, Leaf, Nodes, Dup, MaxDup, Bytes: Int64;
    DupPct: Double;
  end;

  TBlobCol = class
  public
    Table, Column: string;
    Count, Bytes: Int64;
    Avg: Double;
  end;

  TDupPair = class
  public
    Column, AlsoIn: string;
    Matched, Total: Int64;
    Pct: Double;
    RedundantBytes: Int64;
  end;

  TReport = class
  public
    Database: string;
    FileSize: Int64;          { -1: desconhecido }
    PageSize: Int64;
    Header: TStringList;      { Names[i] / ValueFromIndex nao servem: use HeaderKey/HeaderValue }
    HeaderValues: TStringList;
    HasCensus: Boolean;
    CensusTotalPages: Int64;
    Census: TObjectList;      { TCensusRow }
    Tables: TObjectList;      { TTable }
    Indexes: TObjectList;     { TIndex }
    Blobs: TObjectList;       { TBlobCol }
    BlobsMeasured: Boolean;
    HasDup: Boolean;
    Dup: TObjectList;         { TDupPair }
    Findings: TStringList;
    ElapsedMs: Int64;
    constructor Create;
    destructor Destroy; override;
  end;

var
  AnalysisCancel: Boolean;

{ Caminhos de fbclient.dll de 32 bits que existem na maquina. }
procedure CandidateFbClients(Dest: TStrings);
function RunAnalysis(const P: TAnalysisParams; OnProgress: TProgressEvent): TReport;
procedure FillReportJson(R: TReport; O: TJsonObject);

implementation

const
  MIB = 1024 * 1024;
  GIB = 1024 * 1024 * 1024;

{ ------------------------------------------------------------------ }
{ utilitarios                                                         }
{ ------------------------------------------------------------------ }

function FmtN(N: Int64): string;
var
  S: string;
  I: Integer;
begin
  S := IntToStr(N);
  Result := '';
  for I := 1 to Length(S) do
  begin
    if (I > 1) and ((Length(S) - I + 1) mod 3 = 0) then
      Result := Result + '.';
    Result := Result + S[I];
  end;
end;

function FmtF(X: Extended; Decimals: Integer): string;
begin
  Result := Format('%.*f', [Decimals, X]);
end;

function Human(N: Int64): string;
begin
  if N >= GIB then
    Result := FmtF(N / GIB, 2) + ' GiB'
  else if N >= MIB then
    Result := FmtF(N / MIB, 1) + ' MiB'
  else if N >= 1024 then
    Result := FmtF(N / 1024, 1) + ' KiB'
  else
    Result := IntToStr(N) + ' B';
  Result := StringReplace(Result, DecimalSeparator, ',', [rfReplaceAll]);
end;

function PctOf(A, B: Int64): Extended;
begin
  Result := 100.0 * A / B;
end;

function MaxI(A, B: Int64): Int64;
begin
  if A > B then Result := A else Result := B;
end;

function MinI(A, B: Int64): Int64;
begin
  if A < B then Result := A else Result := B;
end;

function IsWs(C: Char): Boolean;
begin
  Result := C in [#9, #10, #13, ' '];
end;

{ Extrai os numeros ("123", "53.00") de uma linha, na ordem em que aparecem. }
function ExtractNums(const S: string; var Nums: array of Extended): Integer;
var
  I, Start: Integer;
  Txt: string;
  IntPart, Frac, Scale: Extended;
  P: Integer;
begin
  Result := 0;
  I := 1;
  while (I <= Length(S)) and (Result <= High(Nums)) do
  begin
    if S[I] in ['0'..'9'] then
    begin
      Start := I;
      while (I <= Length(S)) and (S[I] in ['0'..'9', '.']) do
        Inc(I);
      Txt := Copy(S, Start, I - Start);
      P := Pos('.', Txt);
      if P = 0 then
        Nums[Result] := StrToInt64(Txt)
      else
      begin
        IntPart := 0;
        if P > 1 then IntPart := StrToInt64(Copy(Txt, 1, P - 1));
        Frac := 0;
        Scale := 1;
        Txt := Copy(Txt, P + 1, MaxInt);
        for P := 1 to Length(Txt) do
          if Txt[P] in ['0'..'9'] then
          begin
            Frac := Frac * 10 + (Ord(Txt[P]) - 48);
            Scale := Scale * 10;
          end;
        Nums[Result] := IntPart + Frac / Scale;
      end;
      Inc(Result);
    end
    else
      Inc(I);
  end;
end;

function Contains(const S, Sub: string): Boolean;
begin
  Result := Pos(Sub, S) > 0;
end;

function TryParseInt(const S: string; out V: Int64): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if not (S[I] in ['0'..'9']) then
      Result := False;
  if Result then
    V := StrToInt64(S)
  else
    V := 0;
end;

{ Ordenacao estavel (merge sort) de uma TList. }
type
  TCompareFn = function(A, B: Pointer): Integer;

procedure MergeSortRange(Items, Tmp: PPointerList; L, R: Integer; Cmp: TCompareFn);
var
  M, I, J, K: Integer;
begin
  if R - L < 1 then Exit;
  M := (L + R) div 2;
  MergeSortRange(Items, Tmp, L, M, Cmp);
  MergeSortRange(Items, Tmp, M + 1, R, Cmp);
  I := L;
  J := M + 1;
  K := L;
  while (I <= M) and (J <= R) do
  begin
    if Cmp(Items^[J], Items^[I]) < 0 then
    begin
      Tmp^[K] := Items^[J];
      Inc(J);
    end
    else
    begin
      Tmp^[K] := Items^[I];
      Inc(I);
    end;
    Inc(K);
  end;
  while I <= M do
  begin
    Tmp^[K] := Items^[I];
    Inc(I);
    Inc(K);
  end;
  while J <= R do
  begin
    Tmp^[K] := Items^[J];
    Inc(J);
    Inc(K);
  end;
  for K := L to R do
    Items^[K] := Tmp^[K];
end;

procedure StableSort(List: TList; Cmp: TCompareFn);
var
  Tmp: PPointerList;
begin
  if List.Count < 2 then Exit;
  GetMem(Tmp, List.Count * SizeOf(Pointer));
  try
    MergeSortRange(List.List, Tmp, 0, List.Count - 1, Cmp);
  finally
    FreeMem(Tmp);
  end;
end;

function CmpInt(A, B: Int64): Integer;
begin
  if A < B then Result := -1
  else if A > B then Result := 1
  else Result := 0;
end;

function CmpCensusPages(A, B: Pointer): Integer;
begin
  Result := CmpInt(TCensusRow(B).Pages, TCensusRow(A).Pages);
end;

function CmpBlobBytes(A, B: Pointer): Integer;
begin
  Result := CmpInt(TBlobCol(B).Bytes, TBlobCol(A).Bytes);
end;

function CmpTableTotal(A, B: Pointer): Integer;
begin
  Result := CmpInt(TTable(B).TotalBytes, TTable(A).TotalBytes);
end;

function CmpTableIndexBytes(A, B: Pointer): Integer;
begin
  Result := CmpInt(TTable(B).IndexBytes, TTable(A).IndexBytes);
end;

function CmpTableDataPages(A, B: Pointer): Integer;
begin
  Result := CmpInt(TTable(B).DataPages, TTable(A).DataPages);
end;

function CmpDupRedundant(A, B: Pointer): Integer;
begin
  Result := CmpInt(TDupPair(B).RedundantBytes, TDupPair(A).RedundantBytes);
end;

{ ------------------------------------------------------------------ }
{ TReport                                                             }
{ ------------------------------------------------------------------ }

constructor TReport.Create;
begin
  inherited;
  FileSize := -1;
  Header := TStringList.Create;
  HeaderValues := TStringList.Create;
  Census := TObjectList.Create(True);
  Tables := TObjectList.Create(True);
  Indexes := TObjectList.Create(True);
  Blobs := TObjectList.Create(True);
  Dup := TObjectList.Create(True);
  Findings := TStringList.Create;
end;

destructor TReport.Destroy;
begin
  Header.Free;
  HeaderValues.Free;
  Census.Free;
  Tables.Free;
  Indexes.Free;
  Blobs.Free;
  Dup.Free;
  Findings.Free;
  inherited;
end;

{ ------------------------------------------------------------------ }
{ progresso e cancelamento                                            }
{ ------------------------------------------------------------------ }

type
  TRunner = class
  private
    FOnProgress: TProgressEvent;
    FClient: TFbClient;
  public
    procedure Emit(const Stage: string; Pct: Double; const Msg: string);
    procedure CheckCancel;
    function GstatBytes(Total: Integer): Boolean;
    function HeaderBytes(Total: Integer): Boolean;
  end;

procedure TRunner.Emit(const Stage: string; Pct: Double; const Msg: string);
begin
  if Assigned(FOnProgress) then
    FOnProgress(Stage, Pct, Msg);
end;

procedure TRunner.CheckCancel;
begin
  if AnalysisCancel then
    raise ECancelled.Create('cancelado');
end;

function TRunner.GstatBytes(Total: Integer): Boolean;
begin
  Emit('gstat', -1, 'gstat -a -r · ' + Human(Total) + ' recebidos');
  Result := not AnalysisCancel;
end;

function TRunner.HeaderBytes(Total: Integer): Boolean;
begin
  Result := not AnalysisCancel;
end;

{ ------------------------------------------------------------------ }
{ fbclient                                                            }
{ ------------------------------------------------------------------ }

procedure AddIfFile(Dest: TStrings; const Path: string);
begin
  if FileExists(Path) and IsDll32(Path) and (Dest.IndexOf(Path) < 0) then
    Dest.Add(Path);
end;

procedure CandidateFbClients(Dest: TStrings);
var
  Env, Root: string;
  Dirs: TStringList;
  Sr: TSearchRec;
  I, R: Integer;
  Roots: array[0..1] of string;
  Sys: array[0..MAX_PATH] of Char;
begin
  AddIfFile(Dest, ExtractFilePath(ParamStr(0)) + 'fbclient.dll');
  Env := GetEnvironmentVariable('FIREBIRD');
  if Env <> '' then
  begin
    Env := IncludeTrailingPathDelimiter(Env);
    AddIfFile(Dest, Env + 'bin\fbclient.dll');
    AddIfFile(Dest, Env + 'fbclient.dll');
  end;
  Roots[0] := 'C:\Program Files\Firebird';
  Roots[1] := 'C:\Program Files (x86)\Firebird';
  for R := 0 to 1 do
  begin
    Root := Roots[R];
    if not DirectoryExists(Root) then Continue;
    Dirs := TStringList.Create;
    try
      if FindFirst(Root + '\*', faDirectory, Sr) = 0 then
      try
        repeat
          if ((Sr.Attr and faDirectory) <> 0) and (Sr.Name <> '.') and (Sr.Name <> '..') then
            Dirs.Add(Root + '\' + Sr.Name);
        until FindNext(Sr) <> 0;
      finally
        FindClose(Sr);
      end;
      Dirs.Sort;
      for I := Dirs.Count - 1 downto 0 do
      begin
        AddIfFile(Dest, Dirs[I] + '\bin\fbclient.dll');
        AddIfFile(Dest, Dirs[I] + '\fbclient.dll');
        { o Firebird 64 bits traz o cliente de 32 bits em WOW64 }
        AddIfFile(Dest, Dirs[I] + '\WOW64\fbclient.dll');
      end;
    finally
      Dirs.Free;
    end;
  end;
  if GetWindowsDirectory(Sys, MAX_PATH) > 0 then
  begin
    AddIfFile(Dest, IncludeTrailingPathDelimiter(Sys) + 'SysWOW64bclient.dll');
    AddIfFile(Dest, IncludeTrailingPathDelimiter(Sys) + 'System32bclient.dll');
  end;
end;

function LoadFb(const Explicit: string): TFbClient;
var
  Paths, Tried: TStringList;
  I: Integer;
begin
  Paths := TStringList.Create;
  Tried := TStringList.Create;
  try
    if Trim(Explicit) <> '' then
      Paths.Add(Trim(Explicit));
    CandidateFbClients(Paths);
    Paths.Add('fbclient.dll');
    for I := 0 to Paths.Count - 1 do
      try
        Result := TFbClient.Create(Paths[I]);
        Exit;
      except
        on E: Exception do
          Tried.Add(E.Message);
      end;
    raise EAnalysis.Create('nao consegui carregar a fbclient.dll (a arquitetura precisa ser a mesma do programa: 32 bits):' +
      #10 + Trim(Tried.Text));
  finally
    Paths.Free;
    Tried.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ 1. cabecalho / 3. gstat -a -r                                       }
{ ------------------------------------------------------------------ }

procedure ParseHeader(const Text: string; R: TReport);
var
  Lines, Parts: TStringList;
  I, J, K: Integer;
  Line, T, Key, Val: string;
  Found: Boolean;
begin
  Lines := TStringList.Create;
  Parts := TStringList.Create;
  try
    Lines.Text := Text;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Line = '') or not IsWs(Line[1]) or (Trim(Line) = '') then Continue;
      T := Trim(Line);
      Parts.Clear;
      J := 1;
      while J <= Length(T) do
      begin
        K := J;
        while (K <= Length(T)) and (T[K] <> #9) do Inc(K);
        if Trim(Copy(T, J, K - J)) <> '' then
          Parts.Add(Copy(T, J, K - J));
        J := K + 1;
      end;
      if Parts.Count >= 2 then
      begin
        Key := Trim(Parts[0]);
        while (Key <> '') and (Key[Length(Key)] = ':') do
          Delete(Key, Length(Key), 1);
        Val := '';
        for J := 1 to Parts.Count - 1 do
        begin
          if J > 1 then Val := Val + ' ';
          Val := Val + Trim(Parts[J]);
        end;
      end
      else
      begin
        { regex original: chave em letras/espacos, 2+ espacos, valor }
        Found := False;
        Key := '';
        Val := '';
        if (T <> '') and (T[1] in ['A'..'Z', 'a'..'z']) then
        begin
          J := 2;
          while J < Length(T) do
          begin
            if not (T[J] in ['A'..'Z', 'a'..'z', ' ']) then Break;
            if (J >= 2) and IsWs(T[J + 1]) and (J + 2 <= Length(T)) and IsWs(T[J + 2]) then
            begin
              Key := Trim(Copy(T, 1, J));
              Val := Trim(Copy(T, J + 1, MaxInt));
              Found := Val <> '';
              Break;
            end;
            Inc(J);
          end;
        end;
        if not Found then Continue;
      end;
      R.Header.Add(Key);
      R.HeaderValues.Add(Val);
    end;
  finally
    Lines.Free;
    Parts.Free;
  end;
end;

function HdrNum(R: TReport; const Key: string; out V: Int64): Boolean;
var
  I: Integer;
begin
  Result := False;
  V := 0;
  for I := 0 to R.Header.Count - 1 do
    if R.Header[I] = Key then
    begin
      Result := TryParseInt(Trim(R.HeaderValues[I]), V);
      Exit;
    end;
end;

function IsTableLine(const Line: string; out Name: string): Boolean;
var
  L, P, I: Integer;
  S: string;
begin
  Result := False;
  Name := '';
  S := TrimRight(Line);
  L := Length(S);
  if (L < 4) or IsWs(S[1]) or (S[L] <> ')') then Exit;
  P := L - 1;
  while (P > 0) and (S[P] in ['0'..'9']) do Dec(P);
  if (P = L - 1) or (P < 2) or (S[P] <> '(') or (S[P - 1] <> ' ') then Exit;
  I := P - 2;
  if I < 1 then Exit;
  Name := Copy(S, 1, I);
  Result := True;
end;

function IsIndexLine(const Line: string; out Name: string): Boolean;
var
  S: string;
  L, P: Integer;
begin
  Result := False;
  Name := '';
  if (Line = '') or not IsWs(Line[1]) then Exit;
  S := Trim(Line);
  if Copy(S, 1, 6) <> 'Index ' then Exit;
  L := Length(S);
  if S[L] <> ')' then Exit;
  P := L - 1;
  while (P > 0) and (S[P] in ['0'..'9']) do Dec(P);
  if (P = L - 1) or (P < 8) or (S[P] <> '(') or (S[P - 1] <> ' ') then Exit;
  Name := Copy(S, 7, P - 1 - 7);
  Result := Name <> '';
end;

procedure ParseAnalysis(const Text: string; PageSize: Int64; R: TReport);
var
  Lines: TStringList;
  I, N: Integer;
  Line, Name: string;
  Nums: array[0..3] of Extended;
  Cur: TTable;
  Ix: TIndex;
  InIndex: Boolean;
  T: TTable;
begin
  Lines := TStringList.Create;
  Cur := nil;
  Ix := nil;
  InIndex := False;
  try
    Lines.Text := Text;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if IsTableLine(Line, Name) then
      begin
        Cur := TTable.Create;
        Cur.Name := Name;
        R.Tables.Add(Cur);
        InIndex := False;
        Continue;
      end;
      if Cur = nil then Continue;

      if IsIndexLine(Line, Name) then
      begin
        Ix := TIndex.Create;
        Ix.Table := Cur.Name;
        Ix.Name := Name;
        R.Indexes.Add(Ix);
        Inc(Cur.IndexCount);
        InIndex := True;
        Continue;
      end;
      if Contains(Line, 'Average record length:') and Contains(Line, ', total records:') then
      begin
        N := ExtractNums(Line, Nums);
        if N >= 2 then
        begin
          Cur.AvgRecord := Nums[0];
          Cur.Records := Trunc(Nums[1]);
        end;
      end
      else if Contains(Line, 'Average version length:') and Contains(Line, ', total versions:') then
      begin
        N := ExtractNums(Line, Nums);
        if N >= 3 then
        begin
          Cur.Versions := Trunc(Nums[1]);
          Cur.MaxVersions := Trunc(Nums[2]);
        end;
      end
      else if Contains(Line, 'Data pages:') and Contains(Line, ', data page slots:') then
      begin
        N := ExtractNums(Line, Nums);
        if N >= 3 then
        begin
          Cur.DataPages := Trunc(Nums[0]);
          Cur.Fill := Trunc(Nums[2]);
        end;
      end
      else if Contains(Line, 'Blobs:') and Contains(Line, ', total length:') and Contains(Line, ', blob pages:') then
      begin
        { Firebird 3+ reporta blobs por tabela; 2.5 nao. }
        N := ExtractNums(Line, Nums);
        if N >= 3 then
        begin
          Cur.GstatBlobBytes := Trunc(Nums[1]);
          Cur.BlobPages := Trunc(Nums[2]);
        end;
      end
      else if Contains(Line, 'Depth:') and Contains(Line, ', leaf buckets:') and Contains(Line, ', nodes:') then
      begin
        N := ExtractNums(Line, Nums);
        if InIndex and (Ix <> nil) and (N >= 3) then
        begin
          Ix.Depth := Trunc(Nums[0]);
          Ix.Leaf := Trunc(Nums[1]);
          Ix.Nodes := Trunc(Nums[2]);
          Inc(Cur.IndexPages, Ix.Leaf);
        end;
      end
      else if Contains(Line, 'total dup:') and Contains(Line, ', max dup:') then
      begin
        N := ExtractNums(Line, Nums);
        { a linha comeca com "Average data length: x.xx", entao os contadores sao o 2o e o 3o numero }
        if InIndex and (Ix <> nil) and (N >= 3) then
        begin
          Ix.Dup := Trunc(Nums[1]);
          Ix.MaxDup := Trunc(Nums[2]);
        end;
      end;
    end;
  finally
    Lines.Free;
  end;

  for I := 0 to R.Tables.Count - 1 do
  begin
    T := TTable(R.Tables[I]);
    T.DataBytes := T.DataPages * PageSize;
    T.IndexBytes := T.IndexPages * PageSize;
    T.BlobBytes := MaxI(T.GstatBlobBytes, T.BlobPages * PageSize);
    T.TotalBytes := T.DataBytes + T.IndexBytes + T.BlobBytes;
  end;
  for I := 0 to R.Indexes.Count - 1 do
  begin
    Ix := TIndex(R.Indexes[I]);
    Ix.Bytes := Ix.Leaf * PageSize;
    if Ix.Nodes > 0 then
      Ix.DupPct := 100.0 * Ix.Dup / Ix.Nodes
    else
      Ix.DupPct := 0;
  end;
end;

{ ------------------------------------------------------------------ }
{ 2. censo de paginas                                                 }
{ ------------------------------------------------------------------ }

procedure PageType(T: Integer; out Key, Label_: string);
begin
  case T of
    0: begin Key := 'free'; Label_ := 'Livre / não alocada'; end;
    1: begin Key := 'header'; Label_ := 'Header'; end;
    2: begin Key := 'pip'; Label_ := 'PIP (page inventory)'; end;
    3: begin Key := 'tip'; Label_ := 'TIP (transaction inventory)'; end;
    4: begin Key := 'pointer'; Label_ := 'Pointer'; end;
    5: begin Key := 'data'; Label_ := 'Dados'; end;
    6: begin Key := 'index_root'; Label_ := 'Index root'; end;
    7: begin Key := 'index'; Label_ := 'Índice (b-tree)'; end;
    8: begin Key := 'blob'; Label_ := 'BLOB'; end;
    9: begin Key := 'generator'; Label_ := 'Generator'; end;
    10: begin Key := 'scn'; Label_ := 'SCN inventory'; end;
  else
    Key := 'type_' + IntToStr(T);
    Label_ := Format('Tipo %d (desconhecido)', [T]);
  end;
end;

procedure PageCensus(const Path: string; PageSize, Total: Int64; Run: TRunner; R: TReport);
var
  F: TFileStream;
  Buf: PChar;
  PS, Filled, N, Pages, P: Integer;
  Counts: array[0..255] of Int64;
  Done, TotalPages, Last, T0, Now_: Int64;
  Rate: Double;
  I: Integer;
  Row: TCensusRow;
  Key, Lbl: string;
  PctV: Double;
begin
  PS := PageSize;
  if PS <= 0 then
    raise EAnalysis.Create('page size invalido');
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  GetMem(Buf, PS * 1024);
  try
    FillChar(Counts, SizeOf(Counts), 0);
    Done := 0;
    T0 := GetTickCount;
    Last := T0;
    while True do
    begin
      Filled := 0;
      while Filled < PS * 1024 do
      begin
        N := F.Read(Buf[Filled], PS * 1024 - Filled);
        if N <= 0 then Break;
        Inc(Filled, N);
      end;
      Pages := Filled div PS;
      for P := 0 to Pages - 1 do
        Inc(Counts[Ord(Buf[P * PS])]);
      Inc(Done, Int64(Pages) * PS);
      if Filled < PS * 1024 then Break;
      Run.CheckCancel;
      Now_ := GetTickCount;
      if Now_ - Last > 150 then
      begin
        Last := Now_;
        Rate := Done / (MaxI(Now_ - T0, 1) / 1000.0) / MIB;
        if Total > 0 then PctV := 100.0 * Done / Total else PctV := -1;
        Run.Emit('census', PctV, 'Censo de páginas · ' + Human(Done) + ' · ' +
          Format('%.0f', [Rate]) + ' MiB/s');
      end;
    end;
  finally
    FreeMem(Buf);
    F.Free;
  end;

  TotalPages := 0;
  for I := 0 to 255 do
    Inc(TotalPages, Counts[I]);
  R.CensusTotalPages := TotalPages;
  for I := 0 to 255 do
  begin
    if Counts[I] = 0 then Continue;
    PageType(I, Key, Lbl);
    Row := TCensusRow.Create;
    Row.Key := Key;
    Row.Label_ := Lbl;
    Row.Pages := Counts[I];
    Row.Bytes := Counts[I] * PageSize;
    Row.Pct := 100.0 * Counts[I] / MaxI(TotalPages, 1);
    R.Census.Add(Row);
  end;
  StableSort(R.Census, CmpCensusPages);
  R.HasCensus := True;
end;

{ ------------------------------------------------------------------ }
{ 4. colunas BLOB                                                     }
{ ------------------------------------------------------------------ }

function Q(const Ident: string): string;
begin
  Result := '"' + StringReplace(Ident, '"', '""', [rfReplaceAll]) + '"';
end;

procedure ListBlobColumns(Conn: TFbConn; Tables, Cols: TStringList);
var
  Qry: TFbQuery;
begin
  Qry := Conn.Query(
    'select trim(rf.rdb$relation_name), trim(rf.rdb$field_name) ' +
    'from rdb$relation_fields rf ' +
    'join rdb$fields f on f.rdb$field_name = rf.rdb$field_source ' +
    'join rdb$relations r on r.rdb$relation_name = rf.rdb$relation_name ' +
    'where f.rdb$field_type = 261 and r.rdb$view_blr is null ' +
    'and coalesce(r.rdb$system_flag, 0) = 0 ' +
    'order by rf.rdb$relation_name, rf.rdb$field_name');
  try
    while Qry.Next do
    begin
      Tables.Add(Qry.Text(0));
      Cols.Add(Qry.Text(1));
    end;
  finally
    Qry.Free;
  end;
end;

function SafeInt(const S: string): Int64;
var
  V: Int64;
begin
  if TryParseInt(Trim(S), V) then Result := V else Result := 0;
end;

procedure MeasureBlobs(Conn: TFbConn; CTables, CCols: TStringList; Run: TRunner; R: TReport);
var
  Empty: TStringList;
  TodoT, TodoC: TStringList;
  I, Idx: Integer;
  Qry: TFbQuery;
  B: TBlobCol;
  T: TTable;
  Sql: string;
  Totals: TStringList;   { tabela -> soma (em Objects, como Pointer nao serve para Int64) }
  Sums: array of Int64;
begin
  Empty := TStringList.Create;
  TodoT := TStringList.Create;
  TodoC := TStringList.Create;
  Totals := TStringList.Create;
  try
    Empty.CaseSensitive := True;
    Empty.Sorted := True;
    Empty.Duplicates := dupIgnore;
    for I := 0 to R.Tables.Count - 1 do
      if TTable(R.Tables[I]).Records = 0 then
        Empty.Add(TTable(R.Tables[I]).Name);
    for I := 0 to CTables.Count - 1 do
      if not Empty.Find(CTables[I], Idx) then
      begin
        TodoT.Add(CTables[I]);
        TodoC.Add(CCols[I]);
      end;

    for I := 0 to TodoT.Count - 1 do
    begin
      Run.CheckCancel;
      Run.Emit('blobs', 100.0 * I / MaxI(TodoT.Count, 1),
        Format('BLOBs %d/%d · %s.%s', [I + 1, TodoT.Count, TodoT[I], TodoC[I]]));
      Sql := 'select cast(count(*) as varchar(24)), ' +
        'cast(coalesce(sum(octet_length(' + Q(TodoC[I]) + ')), 0) as varchar(24)) ' +
        'from ' + Q(TodoT[I]) + ' where ' + Q(TodoC[I]) + ' is not null';
      Qry := Conn.Query(Sql);
      try
        if Qry.Next then
        begin
          B := TBlobCol.Create;
          B.Table := TodoT[I];
          B.Column := TodoC[I];
          B.Count := SafeInt(Qry.Text(0));
          B.Bytes := SafeInt(Qry.Text(1));
          if B.Count > 0 then B.Avg := B.Bytes / B.Count else B.Avg := 0;
          R.Blobs.Add(B);
        end;
      finally
        Qry.Free;
      end;
    end;
    StableSort(R.Blobs, CmpBlobBytes);

    Totals.CaseSensitive := True;
    Totals.Sorted := True;
    SetLength(Sums, R.Blobs.Count);
    for I := 0 to R.Blobs.Count - 1 do
    begin
      B := TBlobCol(R.Blobs[I]);
      if Totals.Find(B.Table, Idx) then
        Inc(Sums[Integer(Totals.Objects[Idx])], B.Bytes)
      else
      begin
        Sums[I] := B.Bytes;
        Totals.AddObject(B.Table, TObject(I));
      end;
    end;
    for I := 0 to R.Tables.Count - 1 do
    begin
      T := TTable(R.Tables[I]);
      if Totals.Find(T.Name, Idx) then
        T.BlobPayload := Sums[Integer(Totals.Objects[Idx])]
      else
        T.BlobPayload := 0;
      T.BlobBytes := MaxI(T.GstatBlobBytes, T.BlobPayload);
      T.TotalBytes := T.DataBytes + T.IndexBytes + T.BlobBytes;
    end;
  finally
    Empty.Free;
    TodoT.Free;
    TodoC.Free;
    Totals.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ 5. duplicacao entre colunas BLOB                                    }
{ ------------------------------------------------------------------ }

type
  TInt64Array = array of Int64;
  TCardArray = array of Cardinal;

  { Tabela hash (fingerprint de 64 bits) -> (ocorrencias, tamanho do blob). }
  TFingerMap = class
  private
    FKeys: TInt64Array;
    FCounts: TCardArray;
    FSizes: TInt64Array;
    FUsed: Integer;
    procedure Grow;
    function Slot(Key: Int64): Integer;
  public
    constructor Create;
    procedure Hit(Key, Size: Int64);
    function Contains(Key: Int64): Boolean;
    property Capacity: Integer read FUsed;
  end;

constructor TFingerMap.Create;
begin
  inherited;
  SetLength(FKeys, 1024);
  SetLength(FCounts, 1024);
  SetLength(FSizes, 1024);
end;

function TFingerMap.Slot(Key: Int64): Integer;
var
  M: Integer;
begin
  M := Length(FKeys) - 1;
  Result := Integer(Key and M);
  while (FKeys[Result] <> 0) and (FKeys[Result] <> Key) do
    Result := (Result + 1) and M;
end;

procedure TFingerMap.Grow;
var
  OK: TInt64Array;
  OC: TCardArray;
  OS: TInt64Array;
  I, S: Integer;
begin
  OK := FKeys;
  OC := FCounts;
  OS := FSizes;
  FKeys := nil;
  FCounts := nil;
  FSizes := nil;
  SetLength(FKeys, Length(OK) * 2);
  SetLength(FCounts, Length(OK) * 2);
  SetLength(FSizes, Length(OK) * 2);
  for I := 0 to High(OK) do
    if OK[I] <> 0 then
    begin
      S := Slot(OK[I]);
      FKeys[S] := OK[I];
      FCounts[S] := OC[I];
      FSizes[S] := OS[I];
    end;
end;

procedure TFingerMap.Hit(Key, Size: Int64);
var
  S: Integer;
begin
  if Key = 0 then Key := 1;
  S := Slot(Key);
  if FKeys[S] = 0 then
  begin
    FKeys[S] := Key;
    FSizes[S] := Size;
    Inc(FUsed);
    if FUsed * 2 > Length(FKeys) then
      Grow;
    S := Slot(Key);
  end;
  Inc(FCounts[S]);
end;

function TFingerMap.Contains(Key: Int64): Boolean;
begin
  if Key = 0 then Key := 1;
  Result := FKeys[Slot(Key)] <> 0;
end;

{ FNV-1a de 64 bits sobre (tamanho, bytes). }
function Fingerprint(Size: Int64; const Data: string): Int64;
const
  Prime: Int64 = $100000001B3;
var
  H: Int64;
  I: Integer;
begin
  H := Int64($CBF29CE484222325);
  for I := 0 to 7 do
  begin
    H := H xor ((Size shr (8 * I)) and $FF);
    H := H * Prime;
  end;
  for I := 1 to Length(Data) do
  begin
    H := H xor Ord(Data[I]);
    H := H * Prime;
  end;
  Result := H;
end;

procedure DupScan(Conn: TFbConn; R: TReport; Top: Integer; MinBytes: Int64;
  Offset, Length_: Integer; Run: TRunner);
type
  TMapPrint = record
    Ident: string;
    Map: TFingerMap;
    Total: Int64;
  end;
var
  Cands: TList;
  Prints: array of TMapPrint;
  I, J, K, N: Integer;
  B: TBlobCol;
  Sql, C: string;
  Qry: TFbQuery;
  Size: Int64;
  S: string;
  Best: array of TDupPair;
  Matched, Redundant: Int64;
  Pct: Double;
  Pair: TDupPair;
  Ma, Mb: TFingerMap;
  Idx: Integer;
begin
  Cands := TList.Create;
  try
    for I := 0 to R.Blobs.Count - 1 do
    begin
      if Cands.Count >= Top then Break;
      if TBlobCol(R.Blobs[I]).Bytes >= MinBytes then
        Cands.Add(R.Blobs[I]);
    end;
    R.HasDup := True;
    if Cands.Count < 2 then Exit;

    N := Cands.Count;
    SetLength(Prints, N);
    for I := 0 to N - 1 do
      Prints[I].Map := nil;
    try
      for I := 0 to N - 1 do
      begin
        B := TBlobCol(Cands[I]);
        Prints[I].Ident := B.Table + '.' + B.Column;
        Run.CheckCancel;
        Run.Emit('dup', 100.0 * I / N,
          Format('Duplicação %d/%d · %s (%s)', [I + 1, N, Prints[I].Ident, Human(B.Bytes)]));
        C := Q(B.Column);
        Sql := 'select cast(octet_length(' + C + ') as varchar(24)), ' +
          'cast(substring(' + C + ' from ' + IntToStr(Offset) + ' for ' + IntToStr(Length_) +
          ') as varchar(' + IntToStr(Length_) + ') character set octets) ' +
          'from ' + Q(B.Table) + ' where ' + C + ' is not null';
        Prints[I].Map := TFingerMap.Create;
        Prints[I].Total := 0;
        Qry := Conn.Query(Sql);
        try
          while Qry.Next do
          begin
            if Qry.IsNull(0) or Qry.IsNull(1) then Continue;
            S := Qry.Raw(1);
            if S = '' then Continue;
            Size := SafeInt(Qry.Text(0));
            Prints[I].Map.Hit(Fingerprint(Size, S), Size);
            Inc(Prints[I].Total);
            if (Prints[I].Total mod 65536 = 0) and AnalysisCancel then
              raise ECancelled.Create('cancelado');
          end;
        finally
          Qry.Free;
        end;
      end;

      SetLength(Best, N * N);
      for I := 0 to N * N - 1 do
        Best[I] := nil;
      try
        for I := 0 to N - 1 do
          for J := 0 to N - 1 do
          begin
            if I = J then Continue;
            Ma := Prints[I].Map;
            Mb := Prints[J].Map;
            Matched := 0;
            Redundant := 0;
            for K := 0 to High(Ma.FKeys) do
              if Ma.FKeys[K] <> 0 then
                if Mb.Contains(Ma.FKeys[K]) then
                begin
                  Inc(Matched, Ma.FCounts[K]);
                  Inc(Redundant, Int64(Ma.FCounts[K]) * Ma.FSizes[K]);
                end;
            if (Matched = 0) or (Prints[I].Total = 0) then Continue;
            Pct := 100.0 * Matched / Prints[I].Total;
            if Pct < 5.0 then Continue;
            if I < J then Idx := I * N + J else Idx := J * N + I;
            if (Best[Idx] <> nil) and (Best[Idx].Pct >= Pct) then Continue;
            Best[Idx].Free;
            Pair := TDupPair.Create;
            Pair.Column := Prints[I].Ident;
            Pair.AlsoIn := Prints[J].Ident;
            Pair.Matched := Matched;
            Pair.Total := Prints[I].Total;
            Pair.Pct := Pct;
            Pair.RedundantBytes := Redundant;
            Best[Idx] := Pair;
          end;
        for I := 0 to N * N - 1 do
          if Best[I] <> nil then
          begin
            R.Dup.Add(Best[I]);
            Best[I] := nil;
          end;
      finally
        for I := 0 to High(Best) do
          Best[I].Free;
      end;
      StableSort(R.Dup, CmpDupRedundant);
    finally
      for I := 0 to High(Prints) do
        Prints[I].Map.Free;
    end;
  finally
    Cands.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ observacoes                                                         }
{ ------------------------------------------------------------------ }

function EndsWithTok(const Name, Tok: string): Boolean;
begin
  Result := (Length(Name) >= Length(Tok)) and (Copy(Name, Length(Name) - Length(Tok) + 1, Length(Tok)) = Tok);
end;

function IsWordChar(C: Char): Boolean;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

{ Termina em REMOVER, REMOVE, BKP, BACKUP, OLD, ANTIG, TEMP, TMP, TESTE, COPIA ou _ + 6 a 8 digitos,
  precedido de '_' ou de limite de palavra (sem diferenciar maiusculas). }
function IsJunkName(const Name: string): Boolean;
const
  Toks: array[0..9] of string =
    ('REMOVER', 'REMOVE', 'BKP', 'BACKUP', 'OLD', 'ANTIG', 'TEMP', 'TMP', 'TESTE', 'COPIA');
var
  U, Pre: string;
  I, N, J: Integer;
  AllDigits: Boolean;
begin
  Result := False;
  U := UpperCase(Name);
  for I := 0 to High(Toks) do
    if EndsWithTok(U, Toks[I]) then
    begin
      Pre := Copy(U, 1, Length(U) - Length(Toks[I]));
      if (Pre = '') or (Pre[Length(Pre)] = '_') or not IsWordChar(Pre[Length(Pre)]) then
      begin
        Result := True;
        Exit;
      end;
    end;
  for N := 6 to 8 do
    if (Length(U) > N) and (U[Length(U) - N] = '_') then
    begin
      AllDigits := True;
      for J := Length(U) - N + 1 to Length(U) do
        if not (U[J] in ['0'..'9']) then AllDigits := False;
      if not AllDigits then Continue;
      Pre := Copy(U, 1, Length(U) - N - 1);
      if (Pre = '') or (Pre[Length(Pre)] = '_') or not IsWordChar(Pre[Length(Pre)]) then
      begin
        Result := True;
        Exit;
      end;
    end;
end;

function CensusBytes(R: TReport; const Key: string): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to R.Census.Count - 1 do
    if TCensusRow(R.Census[I]).Key = Key then
    begin
      Result := TCensusRow(R.Census[I]).Bytes;
      Exit;
    end;
end;

procedure BuildFindings(R: TReport);
var
  Out_: TStringList;
  Free_, Blob, Data, IdxB, Tot, Payload: Int64;
  Ver, Rec, Old, Next: Int64;
  I, Deep, Cnt: Integer;
  Heavy, BySize, Low_: TList;
  T: TTable;
  D: TDupPair;
  Eff: Extended;
  PS: Int64;
begin
  Out_ := R.Findings;
  PS := R.PageSize;
  if R.HasCensus then
  begin
    Free_ := CensusBytes(R, 'free');
    Blob := CensusBytes(R, 'blob');
    Data := CensusBytes(R, 'data');
    IdxB := CensusBytes(R, 'index') + CensusBytes(R, 'index_root');
    Tot := MaxI(R.CensusTotalPages * PS, 1);

    if Free_ / Tot > 0.15 then
      Out_.Add(Format('Espaço livre interno de %s (%.0f%% do arquivo). Um backup/restore (gbak) devolveria esse espaço ao sistema de arquivos.',
        [Human(Free_), 100.0 * Free_ / Tot]));
    if Blob / Tot > 0.30 then
      Out_.Add(Format('BLOBs ocupam %.0f%% da base (%s). O crescimento é conteúdo em blob, não registros — veja o ranking de colunas BLOB.',
        [100.0 * Blob / Tot, Human(Blob)]));
    if (IdxB > 0) and (Data > 0) and (IdxB / Data > 0.5) then
      Out_.Add(Format('Índices pesam %.0f%% do volume de dados (%s de índice para %s de dados). Vale auditar índices não usados.',
        [100.0 * IdxB / Data, Human(IdxB), Human(Data)]));
    Payload := 0;
    for I := 0 to R.Blobs.Count - 1 do
      Inc(Payload, TBlobCol(R.Blobs[I]).Bytes);
    if (Payload > 0) and (Blob > 0) then
    begin
      Eff := 100.0 * Payload / Blob;
      if Eff < 90.0 then
      begin
        if Blob > Payload then Old := Blob - Payload else Old := 0;
        Out_.Add(Format('Eficiência de armazenamento de blob em %.0f%%: %s de conteúdo real ocupam %s de páginas (%s desperdiçados em fragmentação). Page size %d é pequeno para o tamanho médio dos blobs.',
          [Eff, Human(Payload), Human(Blob), Human(Old), PS]));
      end;
    end;
  end;

  Ver := 0;
  Rec := 0;
  for I := 0 to R.Tables.Count - 1 do
  begin
    Inc(Ver, TTable(R.Tables[I]).Versions);
    Inc(Rec, TTable(R.Tables[I]).Records);
  end;
  Rec := MaxI(Rec, 1);
  if (Ver > 0) and (Ver / Rec > 0.10) then
    Out_.Add(Format('%s versões de registro para %s registros (%.0f%%): há lixo transacional. Rode um sweep (gfix -sweep) ou backup/restore.',
      [FmtN(Ver), FmtN(Rec), 100.0 * Ver / Rec]));
  if HdrNum(R, 'Oldest transaction', Old) and HdrNum(R, 'Next transaction', Next) then
    if (Next > Old) and (Next - Old > 100000) then
      Out_.Add(Format('Gap de transações de %s (oldest %s -> next %s): há transação antiga presa, impedindo a coleta de versões.',
        [FmtN(Next - Old), FmtN(Old), FmtN(Next)]));

  Deep := 0;
  for I := 0 to R.Indexes.Count - 1 do
    if TIndex(R.Indexes[I]).Depth >= 4 then Inc(Deep);
  if (Deep > 0) and (PS > 0) and (PS <= 4096) then
    Out_.Add(Format('%d índices com depth >= 4 e page size de apenas %d bytes. Aumentar o page size para 8192/16384 reduz a profundidade e o I/O por busca.',
      [Deep, PS]));

  Heavy := TList.Create;
  BySize := TList.Create;
  Low_ := TList.Create;
  try
    for I := 0 to R.Tables.Count - 1 do
    begin
      T := TTable(R.Tables[I]);
      if T.IndexCount >= 10 then Heavy.Add(T);
      BySize.Add(T);
      if (T.DataPages > 2000) and (T.Fill > 0) and (T.Fill < 60) then Low_.Add(T);
    end;
    StableSort(Heavy, CmpTableIndexBytes);
    for I := 0 to MinI(Heavy.Count, 5) - 1 do
    begin
      T := TTable(Heavy[I]);
      Out_.Add(Format('%s tem %d índices somando %s — candidata a revisão de índices redundantes.',
        [T.Name, T.IndexCount, Human(T.IndexBytes)]));
    end;
    StableSort(BySize, CmpTableTotal);
    for I := 0 to BySize.Count - 1 do
    begin
      T := TTable(BySize[I]);
      if IsJunkName(T.Name) and (T.TotalBytes > 10 * MIB) then
        Out_.Add(Format('Tabela ''%s'' (%s, %s registros) tem nome de descarte — confirmar se ainda é necessária.',
          [T.Name, Human(T.TotalBytes), FmtN(T.Records)]));
    end;
    StableSort(Low_, CmpTableDataPages);
    for I := 0 to MinI(Low_.Count, 3) - 1 do
    begin
      T := TTable(Low_[I]);
      Out_.Add(Format('%s com fill de apenas %d%% em %s de dados — páginas mal aproveitadas.',
        [T.Name, T.Fill, Human(T.DataBytes)]));
    end;
  finally
    Heavy.Free;
    BySize.Free;
    Low_.Free;
  end;

  if R.HasDup then
  begin
    Cnt := MinI(R.Dup.Count, 6);
    for I := 0 to Cnt - 1 do
    begin
      D := TDupPair(R.Dup[I]);
      Out_.Add(Format('DUPLICAÇÃO: %.0f%% dos blobs de %s (%s registros) têm conteúdo idêntico a %s — cerca de %s redundantes.',
        [D.Pct, D.Column, FmtN(D.Matched), D.AlsoIn, Human(D.RedundantBytes)]));
    end;
  end;
end;

{ ------------------------------------------------------------------ }
{ orquestracao                                                        }
{ ------------------------------------------------------------------ }

function FileSize64(const Path: string): Int64;
var
  F: TFileStream;
begin
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Result := F.Size;
    finally
      F.Free;
    end;
  except
    Result := -1;
  end;
end;

function RunAnalysis(const P: TAnalysisParams; OnProgress: TProgressEvent): TReport;
var
  Run: TRunner;
  Fb: TFbClient;
  Db, HdrTxt, Txt, Host, Local, LocalPath: string;
  T0: Cardinal;
  PageSize: Int64;
  Conn: TFbConn;
  CT, CC: TStringList;
  Top, Off, Len: Integer;
  MinMb: Double;
begin
  AnalysisCancel := False;
  T0 := GetTickCount;
  Db := Trim(P.Database);
  if Db = '' then
    raise EAnalysis.Create('informe o caminho da base');

  Run := TRunner.Create;
  Run.FOnProgress := OnProgress;
  Result := TReport.Create;
  Fb := nil;
  try
    try
      Run.Emit('init', -1, 'Carregando fbclient.dll…');
      Fb := LoadFb(P.FbClient);
      Run.FClient := Fb;
      Result.Database := Db;

      Run.Emit('header', -1, 'Lendo cabeçalho…');
      HdrTxt := Fb.DbStats(Db, P.User, P.Password, STS_HDR_PAGES, Run.HeaderBytes);
      ParseHeader(HdrTxt, Result);
      if (not HdrNum(Result, 'Page size', PageSize)) or (PageSize <= 0) then
        raise EAnalysis.Create('não consegui ler o page size do cabeçalho');
      Result.PageSize := PageSize;

      { Arquivo acessivel localmente? (base remota => sem censo) }
      SplitHost(Db, Host, Local);
      LocalPath := '';
      if Trim(P.HostFile) <> '' then
        LocalPath := Trim(P.HostFile)
      else if Host = '' then
        LocalPath := Local;
      if (LocalPath <> '') and not FileExists(LocalPath) then
        LocalPath := '';
      if LocalPath <> '' then
        Result.FileSize := FileSize64(LocalPath);

      if P.Census then
      begin
        if LocalPath <> '' then
          PageCensus(LocalPath, PageSize, Result.FileSize, Run, Result)
        else
          Run.Emit('census', -1, 'Censo de páginas ignorado: arquivo não acessível localmente');
      end;

      Run.CheckCancel;
      Run.Emit('gstat', -1, 'gstat -a -r via Services API (pode demorar em bases grandes)…');
      Txt := Fb.DbStats(Db, P.User, P.Password,
        STS_DATA_PAGES or STS_IDX_PAGES or STS_RECORD_VERSIONS, Run.GstatBytes);
      ParseAnalysis(Txt, PageSize, Result);

      if P.Blobs or P.DupScan then
      begin
        Conn := Fb.Connect(Db, P.User, P.Password);
        try
          CT := TStringList.Create;
          CC := TStringList.Create;
          try
            ListBlobColumns(Conn, CT, CC);
            Run.Emit('blobs', 0, Format('%d colunas BLOB no schema', [CT.Count]));
            MeasureBlobs(Conn, CT, CC, Run, Result);
          finally
            CT.Free;
            CC.Free;
          end;
          Result.BlobsMeasured := True;
          if P.DupScan then
          begin
            Top := P.DupTop;
            if Top <= 0 then Top := 6;
            MinMb := P.DupMinMb;
            if MinMb < 0 then MinMb := 64;
            Off := P.DupOffset;
            if Off <= 0 then Off := 200;
            Len := P.DupLength;
            if Len <= 0 then Len := 24;
            DupScan(Conn, Result, Top, Trunc(MinMb * MIB), Off, Len, Run);
          end;
        finally
          Conn.Free;
        end;
      end;

      BuildFindings(Result);
      Run.Emit('done', 100, 'Concluído');
      Result.ElapsedMs := Int64(GetTickCount - T0);
    except
      Result.Free;
      Result := nil;
      raise;
    end;
  finally
    Fb.Free;
    Run.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ JSON (camelCase, igual ao serde do Rust)                            }
{ ------------------------------------------------------------------ }

procedure FillReportJson(R: TReport; O: TJsonObject);
var
  I: Integer;
  A: TJsonArray;
  Item: TJsonObject;
  Pair: TJsonArray;
  T: TTable;
  X: TIndex;
  B: TBlobCol;
  C: TCensusRow;
  D: TDupPair;
begin
  O.Put('database', R.Database);
  if R.FileSize >= 0 then O.Put('fileSize', R.FileSize) else O.Put('fileSize', null);
  O.Put('pageSize', R.PageSize);

  A := O['header'].AsArray;
  for I := 0 to R.Header.Count - 1 do
  begin
    Pair := A.Add.AsArray;
    Pair.Add.AsString := R.Header[I];
    Pair.Add.AsString := R.HeaderValues[I];
  end;

  if R.HasCensus then
  begin
    Item := O['census'].AsObject;
    Item.Put('totalPages', R.CensusTotalPages);
    A := Item['rows'].AsArray;
    for I := 0 to R.Census.Count - 1 do
    begin
      C := TCensusRow(R.Census[I]);
      with A.Add.AsObject do
      begin
        Put('key', C.Key);
        Put('label', C.Label_);
        Put('pages', C.Pages);
        Put('bytes', C.Bytes);
        Put('pct', C.Pct);
      end;
    end;
  end
  else
    O.Put('census', null);

  A := O['tables'].AsArray;
  for I := 0 to R.Tables.Count - 1 do
  begin
    T := TTable(R.Tables[I]);
    with A.Add.AsObject do
    begin
      Put('name', T.Name);
      Put('records', T.Records);
      Put('versions', T.Versions);
      Put('maxVersions', T.MaxVersions);
      Put('avgRecord', T.AvgRecord);
      Put('dataPages', T.DataPages);
      Put('fill', T.Fill);
      Put('indexCount', T.IndexCount);
      Put('indexPages', T.IndexPages);
      Put('blobPages', T.BlobPages);
      Put('gstatBlobBytes', T.GstatBlobBytes);
      Put('blobPayload', T.BlobPayload);
      Put('dataBytes', T.DataBytes);
      Put('indexBytes', T.IndexBytes);
      Put('blobBytes', T.BlobBytes);
      Put('totalBytes', T.TotalBytes);
    end;
  end;

  A := O['indexes'].AsArray;
  for I := 0 to R.Indexes.Count - 1 do
  begin
    X := TIndex(R.Indexes[I]);
    with A.Add.AsObject do
    begin
      Put('table', X.Table);
      Put('name', X.Name);
      Put('depth', X.Depth);
      Put('leaf', X.Leaf);
      Put('nodes', X.Nodes);
      Put('dup', X.Dup);
      Put('maxDup', X.MaxDup);
      Put('bytes', X.Bytes);
      Put('dupPct', X.DupPct);
    end;
  end;

  A := O['blobs'].AsArray;
  for I := 0 to R.Blobs.Count - 1 do
  begin
    B := TBlobCol(R.Blobs[I]);
    with A.Add.AsObject do
    begin
      Put('table', B.Table);
      Put('column', B.Column);
      Put('count', B.Count);
      Put('bytes', B.Bytes);
      Put('avg', B.Avg);
    end;
  end;
  O.Put('blobsMeasured', R.BlobsMeasured);

  if R.HasDup then
  begin
    A := O['dup'].AsObject['pairs'].AsArray;
    for I := 0 to R.Dup.Count - 1 do
    begin
      D := TDupPair(R.Dup[I]);
      with A.Add.AsObject do
      begin
        Put('column', D.Column);
        Put('alsoIn', D.AlsoIn);
        Put('matched', D.Matched);
        Put('total', D.Total);
        Put('pct', D.Pct);
        Put('redundantBytes', D.RedundantBytes);
      end;
    end;
  end
  else
    O.Put('dup', null);

  A := O['findings'].AsArray;
  for I := 0 to R.Findings.Count - 1 do
    A.Add.AsString := R.Findings[I];
  O.Put('elapsedMs', R.ElapsedMs);
end;

end.
