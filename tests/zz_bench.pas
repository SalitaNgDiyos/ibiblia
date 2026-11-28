unit zz_bench;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, Forms, Controls, StdCtrls, Graphics,
  ComCtrls, sqlite3conn, sqldb, Project, Verse, syntagm, project_database_bootstrap,
  ExtCtrls, LCLIntf, BibleScope, ONTTokenizer, FormDictionaryPopup, formprincipal, IniFiles, chapterview, Menus, zzprof, SuggestionManager;

type
  TZZBench = class(TTestCase)
  private
    procedure Run(WithPopup: Boolean; ChapterMode: Integer);
  published
    procedure RightClickAutoAdvance;
    procedure RightClickAutoAdvanceWithPopup;
    procedure WithChapterText;
    procedure WithTranslationMemory;
    procedure WithMainForm;
    procedure SuggestionMicro;
  end;

implementation

function WordsText(N: Integer; Tagged: Boolean): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to N do
  begin
    if I > 1 then
      Result := Result + ' ';
    if Tagged then
      Result := Result + Format('w%d<WG%d><WTN-NSM l="w%d">', [I, 100 + I, I])
    else
      Result := Result + Format('d%d', [I]);
  end;
end;

procedure TZZBench.RightClickAutoAdvance;
begin
  Run(False, 0);
end;

procedure TZZBench.WithChapterText;
begin
  Run(True, 1);
end;

procedure TZZBench.SuggestionMicro;
var
  Dir, DB: string;
  M: TSuggestionManager;
  I, J: Integer;
  T0: Int64;
  D: TTranslationAlternativeDataArray;
  Ref: string;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'zzmicro' + IntToStr(GetTickCount64);
  ForceDirectories(Dir);
  DB := Dir + PathDelim + 'b.bib';
  TProjectDatabaseBootstrap.CreateProjectDatabaseFixture(DB, etNT, 10);
  M := TSuggestionManager.Create(DB);
  try
    for I := 1 to 8 do
    begin
      T0 := ZZNow;
      for J := 1 to 1000 do
      begin
        Ref := Format('40,1,%d', [(I * 1000 + J) mod 900 + 1]);
        M.AddPairForReference(Ref, Format('<wg%d>', [J mod 30]), Format('d%d', [J mod 30]));
        D := M.GetTranslationAlternativeData(Format('<wg%d>', [J mod 30]));
      end;
      WriteLn(StdErr, Format('micro round %d: %d ms', [I, (ZZNow - T0) div 1000]));
    end;
  finally
    M.Free;
  end;
end;

procedure TZZBench.WithMainForm;
const
  VERSES = 240;
  WORDS = 30;
var
  Dir, DB: string;
  C: TSQLite3Connection;
  T: TSQLTransaction;
  Item: TMenuItem;
  P: TProject;
  V, K: Integer;
  Src, Dst: TVerse;
  DstWords: TList;
  S: TSyntagm;
  T0, Total, Worst, Ms: QWord;
  Line: string;
begin
  Application.Initialize;
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'zzbenchmf' + IntToStr(GetTickCount64);
  ForceDirectories(Dir);
  DB := Dir + PathDelim + 'b.bib';
  TProjectDatabaseBootstrap.CreateProjectDatabaseFixture(DB, etNT, VERSES + 2);
  C := TSQLite3Connection.Create(nil);
  T := TSQLTransaction.Create(nil);
  C.Transaction := T;
  C.DatabaseName := DB;
  C.Open;
  T.StartTransaction;
  C.ExecuteDirect('update pares set pare_texto_origem = ''' + WordsText(WORDS, True) +
    ''', pare_texto_destino = ''' + WordsText(WORDS, False) + '''');
  T.Commit;
  T.Free;
  C.Free;

  Application.CreateForm(TMainForm, MainForm);
  if not Assigned(FrmDictionaryPopup) then
    Application.CreateForm(TFrmDictionaryPopup, FrmDictionaryPopup);
  MainForm.MenuItemRecent.Clear;
  Item := TMenuItem.Create(MainForm.MenuItemRecent);
  Item.Caption := DB;
  MainForm.MenuItemRecent.Add(Item);
  MainForm.Show;
  for K := 1 to 20 do
    Application.ProcessMessages;
  P := CurrentProject;
  WriteLn(StdErr, 'mainform project=', Assigned(P));
  if not Assigned(P) then
    Exit;
  for V := 1 to VERSES do
  begin
    Src := P.VerseObjects[tbOrigem];
    Dst := P.VerseObjects[tbDestino];
    DstWords := TList.Create;
    for S in Dst.Syntagms do
      if S.Kind = skSyntagm then
        DstWords.Add(S);
    for S in Src.Syntagms do
      if S.Kind = skSyntagm then
      begin
        S.HandleMouseDown(nil, mbLeft, [], 0, 0);
        Break;
      end;
    Total := 0; Worst := 0;
    for K := 0 to DstWords.Count - 1 do
    begin
      T0 := GetTickCount64;
      TSyntagm(DstWords[K]).HandleMouseDown(nil, mbRight, [], 0, 0);
      Ms := GetTickCount64 - T0;
      Inc(Total, Ms);
      T0 := GetTickCount64;
      Application.ProcessMessages;
      Inc(Worst, GetTickCount64 - T0);
    end;
    DstWords.Free;
    WriteLn(StdErr, Format('mainform verse %d: total ms=%d msgs=%d', [V, Total, Worst]));
    if V mod 40 = 0 then
    begin
      Line := Format('PROF v%d:', [V]);
      for K := 0 to 20 do
      begin
        Line := Line + Format(' s%d=%d', [K, ZZAcc[K] div 40000]);
        ZZAcc[K] := 0;
      end;
      WriteLn(StdErr, Line);
      if GetEnvironmentVariable('ZZCOMMIT') = '1' then
        P.Commit;
    end;
    P.NextVerse;
    Application.ProcessMessages;
  end;
end;

procedure TZZBench.WithTranslationMemory;
begin
  Run(True, 2);
end;

procedure TZZBench.RightClickAutoAdvanceWithPopup;
begin
  Run(True, 0);
end;

procedure TZZBench.Run(WithPopup: Boolean; ChapterMode: Integer);
const
  VERSES = 60;
  WORDS = 30;
var
  Dir, DB: string;
  C: TSQLite3Connection;
  T: TSQLTransaction;
  Host: TForm;
  SP, DP: TScrollBox;
  Combo: TComboBox;
  Tree: TTreeView;
  P: TProject;
  V, K, I: Integer;
  Src, Dst: TVerse;
  DstWords: TList;
  S: TSyntagm;
  T0, T1: QWord;
  Times: array of QWord;
  Line: string;
  SavedOpts: TIniFile;
  Chapter: TChapterView;
begin
  Application.Initialize;
  if not Assigned(opts) then
    opts := TIniFile.Create(IncludeTrailingPathDelimiter(GetTempDir(False)) + 'zzbench.ini');
  if WithPopup and not Assigned(FrmDictionaryPopup) then
  begin
    SavedOpts := opts;
    opts := nil;
    Application.CreateForm(TFrmDictionaryPopup, FrmDictionaryPopup);
    opts := SavedOpts;
    WriteLn(StdErr, 'popup comps=', FrmDictionaryPopup.ComponentCount, ' strongs=', Assigned(FrmDictionaryPopup.Strongs), ' memo=', Assigned(FrmDictionaryPopup.RichMemoStrong));
  end;
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'zzbench' + IntToStr(GetTickCount64);
  ForceDirectories(Dir);
  DB := Dir + PathDelim + 'b.bib';
  TProjectDatabaseBootstrap.CreateProjectDatabaseFixture(DB, etNT, VERSES + 2);
  C := TSQLite3Connection.Create(nil);
  T := TSQLTransaction.Create(nil);
  C.Transaction := T;
  C.DatabaseName := DB;
  C.Open;
  T.StartTransaction;
  C.ExecuteDirect('update pares set pare_texto_origem = ''' + WordsText(WORDS, True) +
    ''', pare_texto_destino = ''' + WordsText(WORDS, False) + '''');
  T.Commit;
  T.Free;
  C.Free;

  Host := TForm.CreateNew(nil);
  Host.SetBounds(0, 0, 1200, 800);
  SP := TScrollBox.Create(Host); SP.Parent := Host; SP.SetBounds(0, 0, 1200, 300);
  DP := TScrollBox.Create(Host); DP.Parent := Host; DP.SetBounds(0, 300, 1200, 300);
  Combo := TComboBox.Create(Host); Combo.Parent := Host;
  Tree := TTreeView.Create(Host); Tree.Parent := Host; Tree.SetBounds(0, 600, 300, 200);
  Host.Show;
  P := TProject.Create([SP, DP], Tree, Combo, nil);
  try
    P.Escopo := etNT;
    if not WithPopup then
      P.PopupTrigger := ptDisabled;
    P.OpenProject(DB);
    Chapter := nil;
    if ChapterMode > 0 then
    begin
      Chapter := TChapterView.Create(Host);
      Chapter.Parent := Host;
      Chapter.SetBounds(300, 600, 900, 200);
      Chapter.Project := P;
      if ChapterMode = 2 then
        Chapter.ViewMode := cvmTranslationMemory;
    end;
    SetLength(Times, 0);
    for V := 1 to VERSES do
    begin
      Src := P.VerseObjects[tbOrigem];
      Dst := P.VerseObjects[tbDestino];
      DstWords := TList.Create;
      for S in Dst.Syntagms do
        if S.Kind = skSyntagm then
          DstWords.Add(S);
      // select the first source word
      for S in Src.Syntagms do
        if S.Kind = skSyntagm then
        begin
          S.HandleMouseDown(nil, mbLeft, [], 0, 0);
          Break;
        end;
      for K := 0 to DstWords.Count - 1 do
      begin
        T0 := GetTickCount64;
        TSyntagm(DstWords[K]).HandleMouseDown(nil, mbRight, [], 0, 0);
        if Assigned(Chapter) and (Src.Selection.Count > 0) then
          Chapter.FocusTranslationMemoryForSyntagm(Src.Selection[Src.Selection.Count - 1]);
        Application.ProcessMessages;
        T1 := GetTickCount64;
        SetLength(Times, Length(Times) + 1);
        Times[High(Times)] := T1 - T0;
      end;
      DstWords.Free;
      Line := Format('popup=%s chapter=%d verse %d: ', [BoolToStr(WithPopup, True), ChapterMode, V]);
      I := 0; T0 := 0;
      for K := Length(Times) - WORDS to High(Times) do
        Inc(T0, Times[K]);
      WriteLn(StdErr, Line, 'total ms=', T0, ' first=', Times[Length(Times) - WORDS],
        ' last=', Times[High(Times)]);
      P.NextVerse;
      Application.ProcessMessages;
    end;
  finally
    if Assigned(Chapter) then
      Chapter.Project := nil;
    P.CloseProject(False);
    P.Free;
    Host.Free;
  end;
end;

initialization
  RegisterTest(TZZBench);
end.
