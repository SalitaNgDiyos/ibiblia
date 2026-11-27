unit github_publisher;

{ Direct GitHub publishing & Timotheos live AMB update engine for The Bible Maker.

  Stores per-project GitHub repository settings in the .bib SQLite info table,
  stores the GitHub Personal Access Token securely via CreateAICredentialStore
  (never inside .bib), exports enabled formats (.nt/.ot/.ont, .usfm.zip, .bbli),
  uploads release assets and/or commits to a branch via the GitHub Git Data API,
  and optionally commits the bundled Bible file to the Timotheos repo so users
  receive the updated Bible automatically in real time. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, ComCtrls,
  Project, BibleScope, project_exporter;

const
  GITHUB_DEFAULT_TIMOTHEOS_REPO = 'https://github.com/SalitaNgDiyos/Timotheos';
  GITHUB_DEFAULT_TIMOTHEOS_BRANCH = 'Neon';
  GITHUB_DEFAULT_TIMOTHEOS_PATH = 'app/renderer/bundled/amb.nt';

type
  TGitHubTextKind = (
    ghtDestinationTagged,
    ghtInterlinearSource,
    ghtSourcePlain
  );

  TGitHubProjectLink = record
    RepoUrl: string;
    TextKind: TGitHubTextKind;
    BaseFileName: string;
    PublishTheWord: Boolean;
    PublishUSFMZip: Boolean;
    PublishESwordBbli: Boolean;
    SyncAboutFromReadme: Boolean;
    UpdateRelease: Boolean;
    ReleaseTag: string;
    CommitToBranch: Boolean;
    BranchName: string;
    BranchFolder: string;
    TimotheosEnabled: Boolean;
    TimotheosRepoUrl: string;
    TimotheosBranch: string;
    TimotheosFilePath: string;
    TimotheosSkipCI: Boolean;
    LastPublishedAt: string;
    LastPublishSummary: string;
  end;

  TGitHubPublishProgressProc = procedure(const Msg: string) of object;

function DefaultGitHubProjectLink(Project: TProject): TGitHubProjectLink;
function LoadGitHubProjectLink(Project: TProject): TGitHubProjectLink;
procedure SaveGitHubProjectLink(Project: TProject; const Link: TGitHubProjectLink);

function ParseGitHubOwnerRepo(const Input: string; out Owner, Repo: string): Boolean;
function NormalizeGitHubRepoUrl(const Input: string): string;
function ScopeTheWordExtension(Scope: TEscopoTexto): string;

function LoadSavedGitHubToken(Ini: TIniFile): string;
procedure SaveGitHubToken(Ini: TIniFile; const Token: string);
procedure ClearGitHubToken(Ini: TIniFile);
function TryDetectGitHubCLIToken(out Token: string): Boolean;
function ResolveGitHubToken(Ini: TIniFile; out SourceLabel: string): string;

function TestGitHubConnection(const Token, Owner, Repo: string;
  out Login, DefaultBranch, LatestTag, ErrMsg: string): Boolean;

function FetchGitHubRepoReadme(const Token, Owner, Repo: string;
  out ReadmeText, ErrMsg: string): Boolean;
function NormalizeReadmeToAboutHtml(const RawReadme: string): string;

function ExportProjectFilesForGitHub(Project: TProject; const Token: string;
  const Link: TGitHubProjectLink; const OutDir: string;
  ProgressBar: TProgressBar; ExportedFiles: TStrings;
  out TheWordFile, ErrMsg: string): Boolean;

function PublishToGitHub(const Token: string; const Link: TGitHubProjectLink;
  ExportedFiles: TStrings; const TheWordFile, CommitMessage: string;
  Progress: TGitHubPublishProgressProc; out ResultSummary, ErrMsg: string): Boolean;

implementation

uses
  StrUtils, DateUtils, Process, fpjson, jsonparser, base64, fphttpclient,
  tls_runtime, ai_credential_store, FileUtil, LazFileUtils;

const
  GITHUB_INI_SECTION = 'GitHub';
  GITHUB_INI_TOKEN_REF_KEY = 'TokenRef';
  GITHUB_API_BASE = 'https://api.github.com';
  GITHUB_UPLOADS_BASE = 'https://uploads.github.com';

  KEY_REPO_URL = 'github.repo_url';
  KEY_TEXT_KIND = 'github.text_kind';
  KEY_BASE_FILENAME = 'github.base_filename';
  KEY_FMT_THEWORD = 'github.fmt.theword';
  KEY_FMT_USFM_ZIP = 'github.fmt.usfm_zip';
  KEY_FMT_ESWORD_BBLI = 'github.fmt.esword_bbli';
  KEY_SYNC_README_ABOUT = 'github.sync_readme_about';
  KEY_UPDATE_RELEASE = 'github.update_release';
  KEY_RELEASE_TAG = 'github.release_tag';
  KEY_COMMIT_BRANCH = 'github.commit_branch_enabled';
  KEY_BRANCH_NAME = 'github.branch_name';
  KEY_BRANCH_FOLDER = 'github.branch_folder';
  KEY_TIM_ENABLED = 'github.timotheos.enabled';
  KEY_TIM_REPO = 'github.timotheos.repo_url';
  KEY_TIM_BRANCH = 'github.timotheos.branch';
  KEY_TIM_PATH = 'github.timotheos.file_path';
  KEY_TIM_SKIP_CI = 'github.timotheos.skip_ci';
  KEY_LAST_PUB_AT = 'github.last_published_at';
  KEY_LAST_PUB_SUMMARY = 'github.last_publish_summary';

function BoolStr(Value: Boolean): string;
begin
  if Value then Result := '1' else Result := '0';
end;

function StrToBoolDefault(const S: string; DefaultVal: Boolean): Boolean;
var
  T: string;
begin
  T := Trim(LowerCase(S));
  if T = '' then Exit(DefaultVal);
  Result := (T = '1') or (T = 'true') or (T = 'yes');
end;

function ScopeTheWordExtension(Scope: TEscopoTexto): string;
begin
  case Scope of
    etOT: Result := '.ot';
    etNT: Result := '.nt';
    etONT: Result := '.ont';
  else
    Result := '.nt';
  end;
end;

function TextKindToStr(Kind: TGitHubTextKind): string;
begin
  case Kind of
    ghtDestinationTagged: Result := 'destination';
    ghtInterlinearSource: Result := 'interlinear';
    ghtSourcePlain: Result := 'source_plain';
  else
    Result := 'destination';
  end;
end;

function StrToTextKind(const S: string): TGitHubTextKind;
var
  T: string;
begin
  T := Trim(LowerCase(S));
  if T = 'interlinear' then Result := ghtInterlinearSource
  else if T = 'source_plain' then Result := ghtSourcePlain
  else Result := ghtDestinationTagged;
end;

function DefaultBaseNameForProject(Project: TProject): string;
var
  Raw, Clean: string;
  I: Integer;
begin
  Raw := '';
  if Assigned(Project) then
    Raw := Trim(ChangeFileExt(ExtractFileName(Project.FileName), ''));
  Clean := '';
  for I := 1 to Length(Raw) do
    if Raw[I] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '-', '_', '.'] then
      Clean := Clean + Raw[I];
  if Clean = '' then
    Clean := 'module';
  Result := Clean;
end;

function DefaultGitHubProjectLink(Project: TProject): TGitHubProjectLink;
begin
  Initialize(Result);
  Result.RepoUrl := '';
  Result.TextKind := ghtDestinationTagged;
  Result.BaseFileName := DefaultBaseNameForProject(Project);
  Result.PublishTheWord := True;
  Result.PublishUSFMZip := True;
  Result.PublishESwordBbli := True;
  Result.SyncAboutFromReadme := True;
  Result.UpdateRelease := True;
  Result.ReleaseTag := '';
  Result.CommitToBranch := False;
  Result.BranchName := '';
  Result.BranchFolder := '';
  Result.TimotheosEnabled := False;
  Result.TimotheosRepoUrl := GITHUB_DEFAULT_TIMOTHEOS_REPO;
  Result.TimotheosBranch := GITHUB_DEFAULT_TIMOTHEOS_BRANCH;
  Result.TimotheosFilePath := GITHUB_DEFAULT_TIMOTHEOS_PATH;
  Result.TimotheosSkipCI := True;
  Result.LastPublishedAt := '';
  Result.LastPublishSummary := '';
end;

function LoadGitHubProjectLink(Project: TProject): TGitHubProjectLink;
var
  V: string;
begin
  Result := DefaultGitHubProjectLink(Project);
  if not Assigned(Project) then
    Exit;

  V := Trim(Project.GetInfo(KEY_REPO_URL));
  if V <> '' then Result.RepoUrl := V;

  V := Trim(Project.GetInfo(KEY_TEXT_KIND));
  if V <> '' then Result.TextKind := StrToTextKind(V);

  V := Trim(Project.GetInfo(KEY_BASE_FILENAME));
  if V <> '' then
    Result.BaseFileName := V
  else if Pos('ang-malayang-biblia-translation', LowerCase(Result.RepoUrl)) > 0 then
    Result.BaseFileName := 'amb+';

  Result.PublishTheWord := StrToBoolDefault(Project.GetInfo(KEY_FMT_THEWORD), True);
  Result.PublishUSFMZip := StrToBoolDefault(Project.GetInfo(KEY_FMT_USFM_ZIP), True);
  Result.PublishESwordBbli := StrToBoolDefault(Project.GetInfo(KEY_FMT_ESWORD_BBLI), True);
  Result.SyncAboutFromReadme := StrToBoolDefault(Project.GetInfo(KEY_SYNC_README_ABOUT), True);
  Result.UpdateRelease := StrToBoolDefault(Project.GetInfo(KEY_UPDATE_RELEASE), True);
  Result.ReleaseTag := Trim(Project.GetInfo(KEY_RELEASE_TAG));
  Result.CommitToBranch := StrToBoolDefault(Project.GetInfo(KEY_COMMIT_BRANCH), False);
  Result.BranchName := Trim(Project.GetInfo(KEY_BRANCH_NAME));
  Result.BranchFolder := Trim(Project.GetInfo(KEY_BRANCH_FOLDER));
  Result.TimotheosEnabled := StrToBoolDefault(Project.GetInfo(KEY_TIM_ENABLED), False);

  V := Trim(Project.GetInfo(KEY_TIM_REPO));
  if V <> '' then Result.TimotheosRepoUrl := V;
  V := Trim(Project.GetInfo(KEY_TIM_BRANCH));
  if V <> '' then Result.TimotheosBranch := V;
  V := Trim(Project.GetInfo(KEY_TIM_PATH));
  if V <> '' then Result.TimotheosFilePath := V;
  Result.TimotheosSkipCI := StrToBoolDefault(Project.GetInfo(KEY_TIM_SKIP_CI), True);

  Result.LastPublishedAt := Trim(Project.GetInfo(KEY_LAST_PUB_AT));
  Result.LastPublishSummary := Trim(Project.GetInfo(KEY_LAST_PUB_SUMMARY));
end;

procedure SaveGitHubProjectLink(Project: TProject; const Link: TGitHubProjectLink);
begin
  if not Assigned(Project) then
    Exit;
  Project.SetInfo(KEY_REPO_URL, NormalizeGitHubRepoUrl(Link.RepoUrl));
  Project.SetInfo(KEY_TEXT_KIND, TextKindToStr(Link.TextKind));
  Project.SetInfo(KEY_BASE_FILENAME, Trim(Link.BaseFileName));
  Project.SetInfo(KEY_FMT_THEWORD, BoolStr(Link.PublishTheWord));
  Project.SetInfo(KEY_FMT_USFM_ZIP, BoolStr(Link.PublishUSFMZip));
  Project.SetInfo(KEY_FMT_ESWORD_BBLI, BoolStr(Link.PublishESwordBbli));
  Project.SetInfo(KEY_SYNC_README_ABOUT, BoolStr(Link.SyncAboutFromReadme));
  Project.SetInfo(KEY_UPDATE_RELEASE, BoolStr(Link.UpdateRelease));
  Project.SetInfo(KEY_RELEASE_TAG, Trim(Link.ReleaseTag));
  Project.SetInfo(KEY_COMMIT_BRANCH, BoolStr(Link.CommitToBranch));
  Project.SetInfo(KEY_BRANCH_NAME, Trim(Link.BranchName));
  Project.SetInfo(KEY_BRANCH_FOLDER, Trim(Link.BranchFolder));
  Project.SetInfo(KEY_TIM_ENABLED, BoolStr(Link.TimotheosEnabled));
  Project.SetInfo(KEY_TIM_REPO, NormalizeGitHubRepoUrl(Link.TimotheosRepoUrl));
  Project.SetInfo(KEY_TIM_BRANCH, Trim(Link.TimotheosBranch));
  Project.SetInfo(KEY_TIM_PATH, Trim(Link.TimotheosFilePath));
  Project.SetInfo(KEY_TIM_SKIP_CI, BoolStr(Link.TimotheosSkipCI));
  if Link.LastPublishedAt <> '' then
    Project.SetInfo(KEY_LAST_PUB_AT, Link.LastPublishedAt);
  if Link.LastPublishSummary <> '' then
    Project.SetInfo(KEY_LAST_PUB_SUMMARY, Link.LastPublishSummary);
end;

function ParseGitHubOwnerRepo(const Input: string; out Owner, Repo: string): Boolean;
var
  S, PathPart: string;
  P, SlashPos: Integer;
  Parts: TStringList;
begin
  Result := False;
  Owner := '';
  Repo := '';
  S := Trim(Input);
  if S = '' then Exit;

  // Strip query or fragment
  P := Pos('?', S);
  if P > 0 then S := Copy(S, 1, P - 1);
  P := Pos('#', S);
  if P > 0 then S := Copy(S, 1, P - 1);

  if AnsiStartsText('git@github.com:', S) then
    PathPart := Copy(S, Length('git@github.com:') + 1, MaxInt)
  else if AnsiStartsText('https://github.com/', S) or AnsiStartsText('http://github.com/', S) then
  begin
    P := Pos('github.com/', LowerCase(S));
    PathPart := Copy(S, P + Length('github.com/'), MaxInt);
  end
  else if AnsiStartsText('https://www.github.com/', S) or AnsiStartsText('http://www.github.com/', S) then
  begin
    P := Pos('github.com/', LowerCase(S));
    PathPart := Copy(S, P + Length('github.com/'), MaxInt);
  end
  else if (Pos('://', S) = 0) and (Pos('/', S) > 0) then
    PathPart := S
  else
    Exit;

  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Trim(PathPart);
    while (Parts.Count > 0) and (Parts[0] = '') do Parts.Delete(0);
    if Parts.Count < 2 then Exit;
    Owner := Trim(Parts[0]);
    Repo := Trim(Parts[1]);
    if AnsiEndsText('.git', Repo) then
      Delete(Repo, Length(Repo) - 3, 4);
    SlashPos := Pos(' ', Owner);
    if (Owner = '') or (Repo = '') or (SlashPos > 0) or (Pos(' ', Repo) > 0) then
    begin
      Owner := '';
      Repo := '';
      Exit;
    end;
    Result := True;
  finally
    Parts.Free;
  end;
end;

function NormalizeGitHubRepoUrl(const Input: string): string;
var
  Owner, Repo: string;
begin
  if ParseGitHubOwnerRepo(Input, Owner, Repo) then
    Result := 'https://github.com/' + Owner + '/' + Repo
  else
    Result := Trim(Input);
end;

{ ------------------------------------------------ Credential storage & gh -- }

function LoadSavedGitHubToken(Ini: TIniFile): string;
var
  Ref: string;
  Store: IAICredentialStore;
begin
  Result := '';
  if not Assigned(Ini) then Exit;
  Ref := Trim(Ini.ReadString(GITHUB_INI_SECTION, GITHUB_INI_TOKEN_REF_KEY, ''));
  if Ref = '' then Exit;
  Store := CreateAICredentialStore;
  try
    if not Store.TryRead(Ref, Result) then
      Result := '';
  except
    Result := '';
  end;
  Result := Trim(Result);
end;

procedure SaveGitHubToken(Ini: TIniFile; const Token: string);
var
  Ref, CleanToken: string;
  Store: IAICredentialStore;
begin
  if not Assigned(Ini) then Exit;
  CleanToken := Trim(Token);
  if CleanToken = '' then
  begin
    ClearGitHubToken(Ini);
    Exit;
  end;
  Store := CreateAICredentialStore;
  Ref := Trim(Ini.ReadString(GITHUB_INI_SECTION, GITHUB_INI_TOKEN_REF_KEY, ''));
  if Ref = '' then
    Ref := NewAICredentialReference;
  Store.Write(Ref, CleanToken);
  Ini.WriteString(GITHUB_INI_SECTION, GITHUB_INI_TOKEN_REF_KEY, Ref);
  Ini.UpdateFile;
end;

procedure ClearGitHubToken(Ini: TIniFile);
var
  Ref: string;
  Store: IAICredentialStore;
begin
  if not Assigned(Ini) then Exit;
  Ref := Trim(Ini.ReadString(GITHUB_INI_SECTION, GITHUB_INI_TOKEN_REF_KEY, ''));
  if Ref <> '' then
  begin
    Store := CreateAICredentialStore;
    try
      Store.Delete(Ref);
    except
    end;
    Ini.DeleteKey(GITHUB_INI_SECTION, GITHUB_INI_TOKEN_REF_KEY);
    Ini.UpdateFile;
  end;
end;

function FindGitHubCLIExecutable: string;
var
  Candidate: string;
begin
  Result := FindDefaultExecutablePath('gh');
  if Result <> '' then Exit;
  {$IFDEF UNIX}
  Candidate := IncludeTrailingPathDelimiter(GetUserDir) + '.local/bin/gh';
  if FileExists(Candidate) then Exit(Candidate);
  if FileExists('/usr/local/bin/gh') then Exit('/usr/local/bin/gh');
  {$ELSE}
  Candidate := GetEnvironmentVariable('ProgramFiles') + '\GitHub CLI\gh.exe';
  if FileExists(Candidate) then Exit(Candidate);
  Candidate := GetEnvironmentVariable('LOCALAPPDATA') + '\Programs\GitHub CLI\gh.exe';
  if FileExists(Candidate) then Exit(Candidate);
  {$ENDIF}
end;

function TryDetectGitHubCLIToken(out Token: string): Boolean;
var
  Exe: string;
  Proc: TProcess;
  OutStream: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N: LongInt;
  Raw: AnsiString;
begin
  Result := False;
  Token := '';
  Exe := FindGitHubCLIExecutable;
  if Exe = '' then Exit;

  Proc := TProcess.Create(nil);
  OutStream := TMemoryStream.Create;
  try
    Proc.Executable := Exe;
    Proc.Parameters.Add('auth');
    Proc.Parameters.Add('token');
    Proc.Options := [poUsePipes, poNoConsole];
    try
      Proc.Execute;
      while Proc.Running do
      begin
        while Proc.Output.NumBytesAvailable > 0 do
        begin
          N := Proc.Output.Read(Buf, SizeOf(Buf));
          if N > 0 then OutStream.Write(Buf, N);
        end;
        Sleep(20);
      end;
      while Proc.Output.NumBytesAvailable > 0 do
      begin
        N := Proc.Output.Read(Buf, SizeOf(Buf));
        if N > 0 then OutStream.Write(Buf, N);
      end;
      if Proc.ExitStatus = 0 then
      begin
        SetString(Raw, PAnsiChar(OutStream.Memory), OutStream.Size);
        Token := Trim(string(Raw));
        Result := Length(Token) >= 20;
        if not Result then Token := '';
      end;
    except
      Token := '';
      Result := False;
    end;
  finally
    OutStream.Free;
    Proc.Free;
  end;
end;

function ResolveGitHubToken(Ini: TIniFile; out SourceLabel: string): string;
begin
  SourceLabel := '';
  Result := LoadSavedGitHubToken(Ini);
  if Result <> '' then
  begin
    SourceLabel := 'Saved secure token';
    Exit;
  end;
  if TryDetectGitHubCLIToken(Result) then
  begin
    SourceLabel := 'GitHub CLI (gh)';
    Exit;
  end;
end;

{ ----------------------------------------------------- GitHub HTTP Helpers -- }

function RuntimeDir: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0)));
end;

function ExtractGitHubErrorMessage(const Body: string; StatusCode: Integer): string;
var
  Root: TJSONData;
  Msg: string;
begin
  Result := Format('HTTP %d', [StatusCode]);
  if Trim(Body) <> '' then
  begin
    try
      Root := GetJSON(Body);
      try
        if (Root <> nil) and (Root.JSONType = jtObject) then
        begin
          Msg := TJSONObject(Root).Get('message', '');
          if Msg <> '' then
            Result := Format('HTTP %d: %s', [StatusCode, Msg]);
        end;
      finally
        Root.Free;
      end;
    except
    end;
  end;
  if StatusCode = 401 then
    Result := Result + ' (Token is invalid or expired.)'
  else if StatusCode = 403 then
    Result := Result + ' (Permission denied: make sure the token has the "repo" scope.)';
end;

function GitHubRequest(const Method, FullUrl, Token, ContentType: string;
  ReqStream: TStream; out RespCode: Integer; out RespBody, ErrMsg: string): Boolean;
var
  Client: TIBibliaHTTPSClient;
  RespStream: TMemoryStream;
  Raw: AnsiString;
begin
  Result := False;
  RespCode := 0;
  RespBody := '';
  ErrMsg := '';
  Client := TIBibliaHTTPSClient.CreateForRuntime(nil, RuntimeDir);
  RespStream := TMemoryStream.Create;
  try
    Client.AllowRedirect := True;
    Client.ConnectTimeout := 15000;
    Client.IOTimeout := 120000;
    Client.AddHeader('User-Agent', 'The-Bible-Maker');
    Client.AddHeader('Accept', 'application/vnd.github+json');
    Client.AddHeader('X-GitHub-Api-Version', '2022-11-28');
    if Token <> '' then
      Client.AddHeader('Authorization', 'Bearer ' + Token);
    if ContentType <> '' then
      Client.AddHeader('Content-Type', ContentType);
    if Assigned(ReqStream) then
    begin
      ReqStream.Position := 0;
      Client.RequestBody := ReqStream;
    end;
    try
      Client.HTTPMethod(Method, FullUrl, RespStream, []);
      RespCode := Client.ResponseStatusCode;
      if RespStream.Size > 0 then
      begin
        SetString(Raw, PAnsiChar(RespStream.Memory), RespStream.Size);
        RespBody := string(Raw);
      end;
      Result := (RespCode >= 200) and (RespCode < 300);
      if not Result then
        ErrMsg := ExtractGitHubErrorMessage(RespBody, RespCode);
    except
      on E: Exception do
      begin
        RespCode := Client.ResponseStatusCode;
        ErrMsg := E.Message;
        Result := False;
      end;
    end;
  finally
    Client.RequestBody := nil;
    RespStream.Free;
    Client.Free;
  end;
end;

function GitHubJsonRequest(const Method, ApiPath, Token: string;
  ReqObj: TJSONObject; out RespCode: Integer; out RespJson: TJSONData;
  out ErrMsg: string): Boolean;
var
  JsonStr, RespBody: string;
  ReqStream: TStringStream;
begin
  RespJson := nil;
  ReqStream := nil;
  try
    if Assigned(ReqObj) then
    begin
      JsonStr := ReqObj.AsJSON;
      ReqStream := TStringStream.Create(JsonStr);
    end;
    Result := GitHubRequest(Method, GITHUB_API_BASE + ApiPath, Token,
      'application/json; charset=utf-8', ReqStream, RespCode, RespBody, ErrMsg);
    if Trim(RespBody) <> '' then
    begin
      try
        RespJson := GetJSON(RespBody);
      except
        RespJson := nil;
      end;
    end;
  finally
    ReqStream.Free;
  end;
end;

function TestGitHubConnection(const Token, Owner, Repo: string;
  out Login, DefaultBranch, LatestTag, ErrMsg: string): Boolean;
var
  Code: Integer;
  Data: TJSONData;
  Perms: TJSONObject;
begin
  Result := False;
  Login := '';
  DefaultBranch := '';
  LatestTag := '';
  ErrMsg := '';
  if Trim(Token) = '' then
  begin
    ErrMsg := 'No GitHub token is configured.';
    Exit;
  end;

  if not GitHubJsonRequest('GET', '/user', Token, nil, Code, Data, ErrMsg) then
  begin
    Data.Free;
    Exit;
  end;
  try
    if Assigned(Data) and (Data.JSONType = jtObject) then
      Login := TJSONObject(Data).Get('login', '');
  finally
    Data.Free;
  end;

  if (Owner = '') or (Repo = '') then
  begin
    Result := True;
    Exit;
  end;

  if not GitHubJsonRequest('GET', '/repos/' + Owner + '/' + Repo, Token, nil, Code, Data, ErrMsg) then
  begin
    Data.Free;
    Exit;
  end;
  try
    if Assigned(Data) and (Data.JSONType = jtObject) then
    begin
      DefaultBranch := TJSONObject(Data).Get('default_branch', 'main');
      Perms := TJSONObject(Data).Get('permissions', TJSONObject(nil));
      if Assigned(Perms) and (not Perms.Get('push', True)) then
      begin
        ErrMsg := Format('Signed in as "%s", but this account does not have write (push) access to %s/%s.',
          [Login, Owner, Repo]);
        Exit;
      end;
    end;
  finally
    Data.Free;
  end;

  if GitHubJsonRequest('GET', '/repos/' + Owner + '/' + Repo + '/releases/latest',
       Token, nil, Code, Data, ErrMsg) then
  begin
    try
      if Assigned(Data) and (Data.JSONType = jtObject) then
        LatestTag := TJSONObject(Data).Get('tag_name', '');
    finally
      Data.Free;
    end;
  end
  else
  begin
    Data.Free;
    if Code = 404 then
    begin
      LatestTag := '(none yet)';
      ErrMsg := '';
    end
    else
      Exit;
  end;
  Result := True;
end;

{ --------------------------------------------- Release Asset Upload Engine -- }

function CreateOrLoadRelease(const Token, Owner, Repo, RequestedTag, ReleaseNotes: string;
  Progress: TGitHubPublishProgressProc; out ReleaseId: Int64; out FinalTag, ReleaseUrl: string;
  out AssetsArray: TJSONArray; out ErrMsg: string): Boolean;
var
  Code: Integer;
  Data: TJSONData;
  Obj, ReqObj: TJSONObject;
  TagToCreate, NotesText: string;

  procedure ExtractReleaseInfo(Src: TJSONData);
  var
    A: TJSONArray;
  begin
    Obj := TJSONObject(Src);
    ReleaseId := Obj.Get('id', Int64(0));
    FinalTag := Obj.Get('tag_name', '');
    ReleaseUrl := Obj.Get('html_url', '');
    A := Obj.Get('assets', TJSONArray(nil));
    if Assigned(A) then
      AssetsArray := TJSONArray(A.Clone)
    else
      AssetsArray := TJSONArray.Create;
  end;

begin
  Result := False;
  ReleaseId := 0;
  FinalTag := '';
  ReleaseUrl := '';
  AssetsArray := nil;
  ErrMsg := '';

  if RequestedTag = '' then
  begin
    if GitHubJsonRequest('GET', '/repos/' + Owner + '/' + Repo + '/releases/latest',
         Token, nil, Code, Data, ErrMsg) then
    begin
      try
        if Assigned(Data) and (Data.JSONType = jtObject) then
        begin
          ExtractReleaseInfo(Data);
          Exit(True);
        end;
      finally
        Data.Free;
      end;
    end
    else
    begin
      Data.Free;
      if Code <> 404 then Exit(False);
    end;
    TagToCreate := FormatDateTime('yyyy.mm.dd', Now);
  end
  else
  begin
    if GitHubJsonRequest('GET', '/repos/' + Owner + '/' + Repo + '/releases/tags/' +
         EncodeURLElement(RequestedTag), Token, nil, Code, Data, ErrMsg) then
    begin
      try
        if Assigned(Data) and (Data.JSONType = jtObject) then
        begin
          ExtractReleaseInfo(Data);
          Exit(True);
        end;
      finally
        Data.Free;
      end;
    end
    else
    begin
      Data.Free;
      if Code <> 404 then Exit(False);
    end;
    TagToCreate := RequestedTag;
  end;

  if Assigned(Progress) then
    Progress('Creating release "' + TagToCreate + '" on ' + Owner + '/' + Repo + '...');

  NotesText := Trim(ReleaseNotes);
  if NotesText = '' then
    NotesText := 'Published from The Bible Maker.';

  ReqObj := TJSONObject.Create;
  try
    ReqObj.Add('tag_name', TagToCreate);
    ReqObj.Add('name', TagToCreate);
    ReqObj.Add('body', NotesText);
    ReqObj.Add('draft', False);
    ReqObj.Add('prerelease', False);
    if not GitHubJsonRequest('POST', '/repos/' + Owner + '/' + Repo + '/releases',
         Token, ReqObj, Code, Data, ErrMsg) then
    begin
      Data.Free;
      Exit(False);
    end;
    try
      if Assigned(Data) and (Data.JSONType = jtObject) then
      begin
        ExtractReleaseInfo(Data);
        Result := True;
      end
      else
        ErrMsg := 'Unexpected JSON response when creating release.';
    finally
      Data.Free;
    end;
  finally
    ReqObj.Free;
  end;
end;

function UploadReleaseAssets(const Token, Owner, Repo, RequestedTag, ReleaseNotes: string;
  Files: TStrings; Progress: TGitHubPublishProgressProc;
  out FinalTag, ReleaseUrl, ErrMsg: string): Boolean;
var
  ReleaseId, AssetId: Int64;
  Assets: TJSONArray;
  I, J, Code: Integer;
  FilePath, AssetName, ExistingName, UploadUrl, RespBody: string;
  AssetObj: TJSONObject;
  DummyData: TJSONData;
  FS: TFileStream;
begin
  Result := False;
  FinalTag := '';
  ReleaseUrl := '';
  ErrMsg := '';
  Assets := nil;

  if not CreateOrLoadRelease(Token, Owner, Repo, RequestedTag, ReleaseNotes,
       Progress, ReleaseId, FinalTag, ReleaseUrl, Assets, ErrMsg) then
    Exit;

  try
    for I := 0 to Files.Count - 1 do
    begin
      FilePath := Files[I];
      AssetName := ExtractFileName(FilePath);

      // Remove existing asset with the same filename so re-uploads replace cleanly
      if Assigned(Assets) then
      begin
        for J := 0 to Assets.Count - 1 do
        begin
          if Assets[J].JSONType <> jtObject then Continue;
          AssetObj := TJSONObject(Assets[J]);
          ExistingName := AssetObj.Get('name', '');
          if SameText(ExistingName, AssetName) then
          begin
            AssetId := AssetObj.Get('id', Int64(0));
            if AssetId > 0 then
            begin
              if Assigned(Progress) then
                Progress('Replacing existing release file: ' + AssetName + '...');
              if not GitHubJsonRequest('DELETE',
                   Format('/repos/%s/%s/releases/assets/%d', [Owner, Repo, AssetId]),
                   Token, nil, Code, DummyData, ErrMsg) then
              begin
                DummyData.Free;
                Exit(False);
              end;
              DummyData.Free;
            end;
          end;
        end;
      end;

      if Assigned(Progress) then
        Progress('Uploading ' + AssetName + ' to release ' + FinalTag + '...');

      UploadUrl := Format('%s/repos/%s/%s/releases/%d/assets?name=%s',
        [GITHUB_UPLOADS_BASE, Owner, Repo, ReleaseId, EncodeURLElement(AssetName)]);
      FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyWrite);
      try
        if not GitHubRequest('POST', UploadUrl, Token, 'application/octet-stream',
             FS, Code, RespBody, ErrMsg) then
          Exit(False);
      finally
        FS.Free;
      end;
    end;
    Result := True;
  finally
    Assets.Free;
  end;
end;

{ ------------------------------------------ Atomic Multi-File Branch Commit -- }

function Base64EncodeFile(const FilePath: string): AnsiString;
var
  MS: TMemoryStream;
  Enc: TBase64EncodingStream;
  OutStr: TStringStream;
begin
  MS := TMemoryStream.Create;
  OutStr := TStringStream.Create('');
  try
    MS.LoadFromFile(FilePath);
    MS.Position := 0;
    Enc := TBase64EncodingStream.Create(OutStr);
    try
      if MS.Size > 0 then
        Enc.CopyFrom(MS, MS.Size);
    finally
      Enc.Free;
    end;
    Result := OutStr.DataString;
  finally
    OutStr.Free;
    MS.Free;
  end;
end;

function NormalizeRepoRelativePath(const RepoPath: string): string;
begin
  Result := StringReplace(Trim(RepoPath), '\', '/', [rfReplaceAll]);
  while (Result <> '') and (Result[1] = '/') do
    Delete(Result, 1, 1);
end;

function CommitFilesToBranch(const Token, Owner, Repo, RequestedBranch, CommitMsg: string;
  LocalPaths, RepoPaths: TStrings; Progress: TGitHubPublishProgressProc;
  out FinalBranch, CommitSha, CommitUrl, ErrMsg: string): Boolean;
var
  Code, I: Integer;
  Data: TJSONData;
  Obj, ReqObj, TreeItem: TJSONObject;
  TreeArr, ParentsArr: TJSONArray;
  HeadSha, BaseTreeSha, BlobSha, NewTreeSha, MsgToUse, B64: string;
begin
  Result := False;
  FinalBranch := Trim(RequestedBranch);
  CommitSha := '';
  CommitUrl := '';
  ErrMsg := '';

  if LocalPaths.Count = 0 then
  begin
    ErrMsg := 'No files to commit.';
    Exit;
  end;
  if LocalPaths.Count <> RepoPaths.Count then
  begin
    ErrMsg := 'Internal mismatch between local files and repository paths.';
    Exit;
  end;

  // 1. Determine default branch if blank
  if FinalBranch = '' then
  begin
    if not GitHubJsonRequest('GET', '/repos/' + Owner + '/' + Repo,
         Token, nil, Code, Data, ErrMsg) then
    begin
      Data.Free;
      Exit;
    end;
    try
      if Assigned(Data) and (Data.JSONType = jtObject) then
        FinalBranch := TJSONObject(Data).Get('default_branch', 'main')
      else
        FinalBranch := 'main';
    finally
      Data.Free;
    end;
  end;

  // 2. Get HEAD commit SHA of branch
  if not GitHubJsonRequest('GET',
       '/repos/' + Owner + '/' + Repo + '/git/ref/heads/' + EncodeURLElement(FinalBranch),
       Token, nil, Code, Data, ErrMsg) then
  begin
    Data.Free;
    Exit;
  end;
  try
    if Assigned(Data) and (Data.JSONType = jtObject) then
    begin
      Obj := TJSONObject(Data).Get('object', TJSONObject(nil));
      if Assigned(Obj) then
        HeadSha := Obj.Get('sha', '');
    end;
  finally
    Data.Free;
  end;
  if HeadSha = '' then
  begin
    ErrMsg := Format('Could not resolve branch "%s" on %s/%s.', [FinalBranch, Owner, Repo]);
    Exit;
  end;

  // 3. Get base tree SHA from HEAD commit
  if not GitHubJsonRequest('GET',
       '/repos/' + Owner + '/' + Repo + '/git/commits/' + HeadSha,
       Token, nil, Code, Data, ErrMsg) then
  begin
    Data.Free;
    Exit;
  end;
  try
    if Assigned(Data) and (Data.JSONType = jtObject) then
    begin
      Obj := TJSONObject(Data).Get('tree', TJSONObject(nil));
      if Assigned(Obj) then
        BaseTreeSha := Obj.Get('sha', '');
    end;
  finally
    Data.Free;
  end;
  if BaseTreeSha = '' then
  begin
    ErrMsg := 'Could not read base tree SHA from HEAD commit.';
    Exit;
  end;

  // 4. Create blobs for each file and assemble tree
  TreeArr := TJSONArray.Create;
  try
    for I := 0 to LocalPaths.Count - 1 do
    begin
      if Assigned(Progress) then
        Progress('Uploading ' + ExtractFileName(LocalPaths[I]) + ' to ' +
          Owner + '/' + Repo + ' (' + FinalBranch + ')...');

      B64 := Base64EncodeFile(LocalPaths[I]);
      ReqObj := TJSONObject.Create;
      try
        ReqObj.Add('content', B64);
        ReqObj.Add('encoding', 'base64');
        if not GitHubJsonRequest('POST', '/repos/' + Owner + '/' + Repo + '/git/blobs',
             Token, ReqObj, Code, Data, ErrMsg) then
        begin
          Data.Free;
          Exit;
        end;
        try
          BlobSha := '';
          if Assigned(Data) and (Data.JSONType = jtObject) then
            BlobSha := TJSONObject(Data).Get('sha', '');
        finally
          Data.Free;
        end;
      finally
        ReqObj.Free;
      end;
      if BlobSha = '' then
      begin
        ErrMsg := 'GitHub did not return a blob SHA for ' + RepoPaths[I];
        Exit;
      end;

      TreeItem := TJSONObject.Create;
      TreeItem.Add('path', NormalizeRepoRelativePath(RepoPaths[I]));
      TreeItem.Add('mode', '100644');
      TreeItem.Add('type', 'blob');
      TreeItem.Add('sha', BlobSha);
      TreeArr.Add(TreeItem);
    end;

    // 5. Create new tree
    ReqObj := TJSONObject.Create;
    try
      ReqObj.Add('base_tree', BaseTreeSha);
      ReqObj.Add('tree', TreeArr);
      TreeArr := nil; // owned by ReqObj now
      if not GitHubJsonRequest('POST', '/repos/' + Owner + '/' + Repo + '/git/trees',
           Token, ReqObj, Code, Data, ErrMsg) then
      begin
        Data.Free;
        Exit;
      end;
      try
        NewTreeSha := '';
        if Assigned(Data) and (Data.JSONType = jtObject) then
          NewTreeSha := TJSONObject(Data).Get('sha', '');
      finally
        Data.Free;
      end;
    finally
      ReqObj.Free;
    end;
  finally
    TreeArr.Free;
  end;

  if NewTreeSha = '' then
  begin
    ErrMsg := 'GitHub did not return a new tree SHA.';
    Exit;
  end;

  // 6. Create commit
  MsgToUse := Trim(CommitMsg);
  if MsgToUse = '' then
    MsgToUse := 'Update module from The Bible Maker';

  ReqObj := TJSONObject.Create;
  try
    ReqObj.Add('message', MsgToUse);
    ReqObj.Add('tree', NewTreeSha);
    ParentsArr := TJSONArray.Create;
    ParentsArr.Add(HeadSha);
    ReqObj.Add('parents', ParentsArr);
    if not GitHubJsonRequest('POST', '/repos/' + Owner + '/' + Repo + '/git/commits',
         Token, ReqObj, Code, Data, ErrMsg) then
    begin
      Data.Free;
      Exit;
    end;
    try
      if Assigned(Data) and (Data.JSONType = jtObject) then
      begin
        CommitSha := TJSONObject(Data).Get('sha', '');
        CommitUrl := TJSONObject(Data).Get('html_url', '');
      end;
    finally
      Data.Free;
    end;
  finally
    ReqObj.Free;
  end;
  if CommitSha = '' then
  begin
    ErrMsg := 'GitHub did not return a commit SHA.';
    Exit;
  end;

  // 7. Advance branch ref
  ReqObj := TJSONObject.Create;
  try
    ReqObj.Add('sha', CommitSha);
    ReqObj.Add('force', False);
    if not GitHubJsonRequest('PATCH',
         '/repos/' + Owner + '/' + Repo + '/git/refs/heads/' + EncodeURLElement(FinalBranch),
         Token, ReqObj, Code, Data, ErrMsg) then
    begin
      Data.Free;
      Exit;
    end;
    Data.Free;
  finally
    ReqObj.Free;
  end;

  if CommitUrl = '' then
    CommitUrl := Format('https://github.com/%s/%s/commit/%s', [Owner, Repo, CommitSha]);
  Result := True;
end;

{ -------------------------------------------------- Project Export Staging -- }

function BuildSavedDestinationOptions(Project: TProject): TOpcoesExportacao;
begin
  Result := [];
  if StrToBoolDefault(Project.GetInfo('opcoes.exportar.na.como.italicos'), False) then
    Include(Result, oeExportarNAComoItalicos);
  if StrToBoolDefault(Project.GetInfo('opcoes.exportar.comentarios'), False) then
    Include(Result, oeExportarComentarios);
  if StrToBoolDefault(Project.GetInfo('opcoes.exportar.morfologia'), False) then
    Include(Result, oeExportarMorfologia);
  if StrToBoolDefault(Project.GetInfo('opcoes.exportar.strongs.reutilizados'), False) then
    Include(Result, oeStrongsReutilizados);
  if StrToBoolDefault(Project.GetInfo('opcoes.exportar.strongs.nao.traduzidos'), False) then
    Include(Result, oeStrongsNaoTraduzidos);
end;

function RunSingleExport(Project: TProject; Kind: TGitHubTextKind;
  const FileName: string; ProgressBar: TProgressBar;
  const Opts: TOpcoesExportacao; out ErrMsg: string): Boolean;
var
  Res: TExportResult;
begin
  ErrMsg := '';
  case Kind of
    ghtDestinationTagged:
      Res := Project.ExportDestinationTextWithStrongs(FileName, ProgressBar, Opts);
    ghtInterlinearSource:
      Res := Project.ExportInterlinearText(FileName, ProgressBar, []);
    ghtSourcePlain:
      Res := Project.ExportPlainSourceText(FileName, ProgressBar);
  else
    Res := Project.ExportDestinationTextWithStrongs(FileName, ProgressBar, Opts);
  end;
  Result := Res.Status <> esFailed;
  if not Result then
    ErrMsg := Res.ErrorMessage;
end;

function FetchGitHubRepoReadme(const Token, Owner, Repo: string;
  out ReadmeText, ErrMsg: string): Boolean;
var
  Code: Integer;
  Data: TJSONData;
  Obj: TJSONObject;
  Enc, B64, CleanB64: string;
  I: Integer;
begin
  Result := False;
  ReadmeText := '';
  ErrMsg := '';
  if (Trim(Owner) = '') or (Trim(Repo) = '') then
  begin
    ErrMsg := 'Invalid GitHub repository.';
    Exit;
  end;

  if not GitHubJsonRequest('GET', '/repos/' + Owner + '/' + Repo + '/readme',
       Token, nil, Code, Data, ErrMsg) then
  begin
    Data.Free;
    Exit;
  end;
  try
    if (not Assigned(Data)) or (Data.JSONType <> jtObject) then
    begin
      ErrMsg := 'Unexpected GitHub README response.';
      Exit;
    end;
    Obj := TJSONObject(Data);
    Enc := LowerCase(Trim(Obj.Get('encoding', '')));
    B64 := Obj.Get('content', '');
    if (Enc = 'base64') and (B64 <> '') then
    begin
      CleanB64 := '';
      for I := 1 to Length(B64) do
        if not (B64[I] in [#10, #13, ' ', #9]) then
          CleanB64 := CleanB64 + B64[I];
      ReadmeText := DecodeStringBase64(CleanB64);
      Result := True;
    end
    else if B64 <> '' then
    begin
      ReadmeText := B64;
      Result := True;
    end
    else
      ErrMsg := 'Repository README is empty.';
  finally
    Data.Free;
  end;
end;

function NormalizeReadmeToAboutHtml(const RawReadme: string): string;
var
  S: string;
begin
  S := Trim(RawReadme);
  if S = '' then Exit('');
  // Strip UTF-8 BOM if present
  if (Length(S) >= 3) and (S[1] = #$EF) and (S[2] = #$BB) and (S[3] = #$BF) then
    Delete(S, 1, 3);
  S := StringReplace(S, #13#10, ' ', [rfReplaceAll]);
  S := StringReplace(S, #13, ' ', [rfReplaceAll]);
  S := StringReplace(S, #10, ' ', [rfReplaceAll]);
  while Pos('  ', S) > 0 do
    S := StringReplace(S, '  ', ' ', [rfReplaceAll]);
  S := StringReplace(S, '> <', '><', [rfReplaceAll]);
  Result := Trim(S);
end;

function UpsertAboutInProperties(const Props, AboutHtml: string): string;
var
  Lines: TStringList;
  I: Integer;
  Found: Boolean;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := Props;
    Found := False;
    for I := 0 to Lines.Count - 1 do
    begin
      if AnsiStartsText('about=', TrimLeft(Lines[I])) then
      begin
        Lines[I] := 'about=' + AboutHtml;
        Found := True;
        Break;
      end;
    end;
    if not Found then
      Lines.Add('about=' + AboutHtml);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function ExportProjectFilesForGitHub(Project: TProject; const Token: string;
  const Link: TGitHubProjectLink; const OutDir: string;
  ProgressBar: TProgressBar; ExportedFiles: TStrings;
  out TheWordFile, ErrMsg: string): Boolean;
var
  Base, Ext, FPath, Owner, Repo, RawReadme, AboutHtml, ReadmeErr, PropKey: string;
  Opts: TOpcoesExportacao;
begin
  Result := False;
  TheWordFile := '';
  ErrMsg := '';
  ExportedFiles.Clear;

  if not Assigned(Project) then
  begin
    ErrMsg := 'No project is open.';
    Exit;
  end;

  if Link.SyncAboutFromReadme and ParseGitHubOwnerRepo(Link.RepoUrl, Owner, Repo) then
  begin
    if FetchGitHubRepoReadme(Token, Owner, Repo, RawReadme, ReadmeErr) then
    begin
      AboutHtml := NormalizeReadmeToAboutHtml(RawReadme);
      if AboutHtml <> '' then
      begin
        if Link.TextKind = ghtDestinationTagged then
          PropKey := 'propriedades.destino'
        else
          PropKey := 'propriedades.origem';
        Project.SetInfo(PropKey, UpsertAboutInProperties(Project.GetInfo(PropKey), AboutHtml));
      end;
    end;
  end;

  Base := Trim(Link.BaseFileName);
  if Base = '' then
    Base := DefaultBaseNameForProject(Project);
  Ext := ScopeTheWordExtension(Project.Escopo);
  Opts := BuildSavedDestinationOptions(Project);
  ForceDirectories(OutDir);

  if Link.PublishTheWord or Link.TimotheosEnabled then
  begin
    FPath := IncludeTrailingPathDelimiter(OutDir) + Base + Ext;
    if not RunSingleExport(Project, Link.TextKind, FPath, ProgressBar, Opts, ErrMsg) then
      Exit;
    TheWordFile := FPath;
    if Link.PublishTheWord then
      ExportedFiles.Add(FPath);
  end;

  if Link.PublishUSFMZip then
  begin
    FPath := IncludeTrailingPathDelimiter(OutDir) + Base + '.usfm.zip';
    if not RunSingleExport(Project, Link.TextKind, FPath, ProgressBar, Opts, ErrMsg) then
      Exit;
    ExportedFiles.Add(FPath);
  end;

  if Link.PublishESwordBbli then
  begin
    FPath := IncludeTrailingPathDelimiter(OutDir) + Base + '.bbli';
    if not RunSingleExport(Project, Link.TextKind, FPath, ProgressBar, Opts, ErrMsg) then
      Exit;
    ExportedFiles.Add(FPath);
  end;

  if (ExportedFiles.Count = 0) and (not Link.TimotheosEnabled) then
  begin
    ErrMsg := 'Select at least one export format or enable Timotheos publishing.';
    Exit;
  end;

  Result := True;
end;

function PublishToGitHub(const Token: string; const Link: TGitHubProjectLink;
  ExportedFiles: TStrings; const TheWordFile, CommitMessage: string;
  Progress: TGitHubPublishProgressProc; out ResultSummary, ErrMsg: string): Boolean;
var
  Owner, Repo, TimOwner, TimRepo: string;
  FinalTag, ReleaseUrl, FinalBranch, CommitSha, CommitUrl: string;
  TimBranch, TimSha, TimUrl, TimMsg: string;
  RepoPaths, TimLocal, TimRemote: TStringList;
  Folder, RelPath, BaseMsg: string;
  I: Integer;
  SummaryParts: TStringList;
begin
  Result := False;
  ResultSummary := '';
  ErrMsg := '';

  if Trim(Token) = '' then
  begin
    ErrMsg := 'No GitHub token is configured. Go to the GitHub Connection tab to sign in.';
    Exit;
  end;

  SummaryParts := TStringList.Create;
  try
    if Link.UpdateRelease or Link.CommitToBranch then
    begin
      if not ParseGitHubOwnerRepo(Link.RepoUrl, Owner, Repo) then
      begin
        ErrMsg := 'Invalid project GitHub repository URL: ' + Link.RepoUrl;
        Exit;
      end;

      if Link.UpdateRelease and (ExportedFiles.Count > 0) then
      begin
        if not UploadReleaseAssets(Token, Owner, Repo, Link.ReleaseTag,
             CommitMessage, ExportedFiles, Progress, FinalTag, ReleaseUrl, ErrMsg) then
          Exit;
        SummaryParts.Add('Release ' + FinalTag + ': ' + ReleaseUrl);
      end;

      if Link.CommitToBranch and (ExportedFiles.Count > 0) then
      begin
        RepoPaths := TStringList.Create;
        try
          Folder := NormalizeRepoRelativePath(Link.BranchFolder);
          for I := 0 to ExportedFiles.Count - 1 do
          begin
            if Folder <> '' then
              RelPath := Folder + '/' + ExtractFileName(ExportedFiles[I])
            else
              RelPath := ExtractFileName(ExportedFiles[I]);
            RepoPaths.Add(RelPath);
          end;
          BaseMsg := Trim(CommitMessage);
          if BaseMsg = '' then
            BaseMsg := 'Update ' + Trim(Link.BaseFileName) + ' from The Bible Maker';
          if not CommitFilesToBranch(Token, Owner, Repo, Link.BranchName, BaseMsg,
               ExportedFiles, RepoPaths, Progress, FinalBranch, CommitSha, CommitUrl, ErrMsg) then
            Exit;
          SummaryParts.Add('Branch ' + FinalBranch + ': ' + CommitUrl);
        finally
          RepoPaths.Free;
        end;
      end;
    end;

    if Link.TimotheosEnabled then
    begin
      if (TheWordFile = '') or (not FileExists(TheWordFile)) then
      begin
        ErrMsg := 'Internal error: missing exported theWord Bible file for Timotheos.';
        Exit;
      end;
      if not ParseGitHubOwnerRepo(Link.TimotheosRepoUrl, TimOwner, TimRepo) then
      begin
        ErrMsg := 'Invalid Timotheos repository URL: ' + Link.TimotheosRepoUrl;
        Exit;
      end;

      TimLocal := TStringList.Create;
      TimRemote := TStringList.Create;
      try
        TimLocal.Add(TheWordFile);
        RelPath := NormalizeRepoRelativePath(Link.TimotheosFilePath);
        if RelPath = '' then
          RelPath := GITHUB_DEFAULT_TIMOTHEOS_PATH;
        TimRemote.Add(RelPath);

        TimMsg := Trim(CommitMessage);
        if TimMsg = '' then
          TimMsg := 'Update bundled Bible (' + ExtractFileName(TheWordFile) + ') from The Bible Maker';
        if Link.TimotheosSkipCI and (Pos('[skip ci]', LowerCase(TimMsg)) = 0) then
          TimMsg := TimMsg + ' [skip ci]';

        if not CommitFilesToBranch(Token, TimOwner, TimRepo, Link.TimotheosBranch,
             TimMsg, TimLocal, TimRemote, Progress, TimBranch, TimSha, TimUrl, ErrMsg) then
          Exit;
        SummaryParts.Add('Timotheos (' + TimBranch + '): ' + TimUrl);
      finally
        TimLocal.Free;
        TimRemote.Free;
      end;
    end;

    if SummaryParts.Count = 0 then
    begin
      ErrMsg := 'No publishing target was enabled (Release, Branch commit, or Timotheos).';
      Exit;
    end;

    ResultSummary := SummaryParts.Text;
    Result := True;
  finally
    SummaryParts.Free;
  end;
end;

end.
