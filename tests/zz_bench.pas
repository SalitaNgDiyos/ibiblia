unit zz_bench;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, Forms, Controls, StdCtrls, Graphics,
  ComCtrls, sqlite3conn, sqldb, Project, Verse, syntagm, project_database_bootstrap,
  ExtCtrls, LCLIntf, BibleScope, ONTTokenizer, FormDictionaryPopup, formprincipal, IniFiles;

type
  TZZBench = class(TTestCase)
  private
    procedure Run(WithPopup: Boolean);
  published
    procedure RightClickAutoAdvance;
    procedure RightClickAutoAdvanceWithPopup;
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
  Run(False);
end;

procedure TZZBench.RightClickAutoAdvanceWithPopup;
begin
  Run(True);
end;

procedure TZZBench.Run(WithPopup: Boolean);
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
        Application.ProcessMessages;
        T1 := GetTickCount64;
        SetLength(Times, Length(Times) + 1);
        Times[High(Times)] := T1 - T0;
      end;
      DstWords.Free;
      Line := Format('popup=%s verse %d: ', [BoolToStr(WithPopup, True), V]);
      I := 0; T0 := 0;
      for K := Length(Times) - WORDS to High(Times) do
        Inc(T0, Times[K]);
      WriteLn(StdErr, Line, 'total ms=', T0, ' first=', Times[Length(Times) - WORDS],
        ' last=', Times[High(Times)]);
      P.NextVerse;
      Application.ProcessMessages;
    end;
  finally
    P.CloseProject(False);
    P.Free;
    Host.Free;
  end;
end;

initialization
  RegisterTest(TZZBench);
end.
