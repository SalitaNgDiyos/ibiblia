unit form_github_publish;

{ Skinned modal dialog for linking an iBiblia project to a GitHub repository
  and publishing exported Bible modules directly to GitHub Releases, branches,
  and the Timotheos Bible app (real-time live AMB updates). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, Controls, Forms,
  Project;

function ShowGitHubPublishDialog(AOwner: TComponent; AProject: TProject;
  AIni: TIniFile): Boolean;

implementation

uses
  StdCtrls, ExtCtrls, ComCtrls, Dialogs, Graphics, LCLIntf, LazFileUtils, FileUtil,
  Math,
  ui_style, unitskins, github_publisher, project_change_log;

type
  TGitHubPublishForm = class;

  TGitHubPublishWorker = class(TThread)
  private
    FOwnerForm: TGitHubPublishForm;
    FToken: string;
    FLink: TGitHubProjectLink;
    FFiles: TStringList;
    FTheWordFile: string;
    FCommitMsg: string;
    FPendingLogMsg: string;
    FSuccess: Boolean;
    FResultSummary: string;
    FErrMsg: string;
    procedure ThreadProgress(const Msg: string);
    procedure SyncAppendLog;
    procedure SyncCompleted;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwnerForm: TGitHubPublishForm; const AToken: string;
      const ALink: TGitHubProjectLink; AFiles: TStrings;
      const ATheWordFile, ACommitMsg: string);
    destructor Destroy; override;
  end;

  TGitHubPublishForm = class(TForm)
  private
    FProject: TProject;
    FIni: TIniFile;
    FPageControl: TPageControl;
    FTabPublish: TTabSheet;
    FTabConnection: TTabSheet;

    // Publish tab
    FGrpRepo: TGroupBox;
    FLblRepo: TLabel;
    FEditRepoUrl: TEdit;
    FLblTokenBadge: TLabel;

    FGrpContent: TGroupBox;
    FLblTextKind: TLabel;
    FComboTextKind: TComboBox;
    FLblBaseName: TLabel;
    FEditBaseName: TEdit;
    FLblFormats: TLabel;
    FCbFmtTheWord: TCheckBox;
    FCbFmtUsfmZip: TCheckBox;
    FCbFmtESwordBbli: TCheckBox;
    FLblPreview: TLabel;

    FGrpTargets: TGroupBox;
    FCbUpdateRelease: TCheckBox;
    FLblReleaseTag: TLabel;
    FEditReleaseTag: TEdit;
    FCbCommitBranch: TCheckBox;
    FEditBranchName: TEdit;
    FLblBranchFolder: TLabel;
    FEditBranchFolder: TEdit;
    FCbTimotheos: TCheckBox;
    FLblTimotheosSummary: TLabel;

    FLblCommitMsg: TLabel;
    FEditCommitMsg: TEdit;
    FProgressBar: TProgressBar;
    FMemoLog: TMemo;

    // Connection & Timotheos tab
    FGrpAuth: TGroupBox;
    FLblAuthHelp: TLabel;
    FLblToken: TLabel;
    FEditToken: TEdit;
    FBtnDetectCLI: TButton;
    FBtnOpenTokenPage: TButton;
    FBtnSaveToken: TButton;
    FBtnClearToken: TButton;
    FBtnTestConn: TButton;
    FLblConnStatus: TLabel;

    FGrpTimotheosCfg: TGroupBox;
    FLblTimRepo: TLabel;
    FEditTimRepo: TEdit;
    FLblTimBranch: TLabel;
    FEditTimBranch: TEdit;
    FLblTimPath: TLabel;
    FEditTimPath: TEdit;
    FCbTimSkipCI: TCheckBox;

    // Footer
    FFooterPanel: TPanel;
    FLblLastPublished: TLabel;
    FBtnSave: TButton;
    FBtnPublish: TButton;
    FBtnClose: TButton;

    FPublishing: Boolean;
    FSettingsSaved: Boolean;
    FTempDir: string;
    FWorker: TGitHubPublishWorker;
    FClosingAfterDone: Boolean;

    procedure BuildUI;
    procedure ApplyTheme;
    procedure LoadFromProject;
    function CollectLinkFromUI: TGitHubProjectLink;
    procedure RefreshPreviews(Sender: TObject);
    procedure RefreshTokenStatusBadge;
    procedure AppendLog(const Msg: string);
    procedure SetControlsEnabledForPublish(Idle: Boolean);
    procedure FormShowHandler(Sender: TObject);
    procedure FormCloseQueryHandler(Sender: TObject; var CanClose: Boolean);
    procedure PageControlChangeHandler(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure PublishClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure DetectCLIClick(Sender: TObject);
    procedure OpenTokenPageClick(Sender: TObject);
    procedure SaveTokenClick(Sender: TObject);
    procedure ClearTokenClick(Sender: TObject);
    procedure TestConnClick(Sender: TObject);
    procedure WorkerFinished(ASuccess: Boolean; const ASummary, AErrMsg: string;
      const APublishedLink: TGitHubProjectLink);
  public
    constructor CreateDialog(AOwner: TComponent; AProject: TProject; AIni: TIniFile);
    destructor Destroy; override;
    property SettingsSaved: Boolean read FSettingsSaved;
  end;

function ShowGitHubPublishDialog(AOwner: TComponent; AProject: TProject;
  AIni: TIniFile): Boolean;
var
  Dlg: TGitHubPublishForm;
begin
  Result := False;
  if not Assigned(AProject) then
    Exit;
  Dlg := TGitHubPublishForm.CreateDialog(AOwner, AProject, AIni);
  try
    Dlg.ShowModal;
    Result := Dlg.SettingsSaved;
  finally
    Dlg.Free;
  end;
end;

{ ----------------------------------------------------- TGitHubPublishWorker -- }

constructor TGitHubPublishWorker.Create(AOwnerForm: TGitHubPublishForm;
  const AToken: string; const ALink: TGitHubProjectLink; AFiles: TStrings;
  const ATheWordFile, ACommitMsg: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwnerForm := AOwnerForm;
  FToken := AToken;
  FLink := ALink;
  FFiles := TStringList.Create;
  if Assigned(AFiles) then
    FFiles.AddStrings(AFiles);
  FTheWordFile := ATheWordFile;
  FCommitMsg := ACommitMsg;
end;

destructor TGitHubPublishWorker.Destroy;
begin
  FFiles.Free;
  inherited Destroy;
end;

procedure TGitHubPublishWorker.ThreadProgress(const Msg: string);
begin
  FPendingLogMsg := Msg;
  Synchronize(@SyncAppendLog);
end;

procedure TGitHubPublishWorker.SyncAppendLog;
begin
  if Assigned(FOwnerForm) then
    FOwnerForm.AppendLog(FPendingLogMsg);
end;

procedure TGitHubPublishWorker.SyncCompleted;
begin
  if Assigned(FOwnerForm) then
    FOwnerForm.WorkerFinished(FSuccess, FResultSummary, FErrMsg, FLink);
end;

procedure TGitHubPublishWorker.Execute;
begin
  FSuccess := False;
  FResultSummary := '';
  FErrMsg := '';
  try
    FSuccess := PublishToGitHub(FToken, FLink, FFiles, FTheWordFile,
      FCommitMsg, @ThreadProgress, FResultSummary, FErrMsg);
  except
    on E: Exception do
    begin
      FSuccess := False;
      FErrMsg := E.Message;
    end;
  end;
  Synchronize(@SyncCompleted);
end;

{ ------------------------------------------------------- TGitHubPublishForm -- }

constructor TGitHubPublishForm.CreateDialog(AOwner: TComponent;
  AProject: TProject; AIni: TIniFile);
begin
  inherited CreateNew(AOwner);
  FProject := AProject;
  FIni := AIni;
  FPublishing := False;
  FSettingsSaved := False;
  FTempDir := '';
  FWorker := nil;
  FClosingAfterDone := False;
  BuildUI;
  LoadFromProject;
  ApplyTheme;
end;

destructor TGitHubPublishForm.Destroy;
begin
  if Assigned(FWorker) then
  begin
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
  if (FTempDir <> '') and DirectoryExists(FTempDir) then
    DeleteDirectory(FTempDir, False);
  inherited Destroy;
end;

procedure TGitHubPublishForm.BuildUI;
var
  PW, M: Integer;
begin
  Caption := 'Publish to GitHub';
  Position := poMainFormCenter;
  BorderStyle := bsSizeable;
  Width := UIScale(Self, 740);
  Height := UIScale(Self, 680);
  Constraints.MinWidth := UIScale(Self, 680);
  Constraints.MinHeight := UIScale(Self, 610);
  OnShow := @FormShowHandler;
  OnCloseQuery := @FormCloseQueryHandler;

  M := UIScale(Self, 12);

  FFooterPanel := TPanel.Create(Self);
  FFooterPanel.Parent := Self;
  FFooterPanel.Align := alBottom;
  FFooterPanel.Height := UIScale(Self, 52);
  FFooterPanel.BevelOuter := bvNone;

  FLblLastPublished := TLabel.Create(Self);
  FLblLastPublished.Parent := FFooterPanel;
  FLblLastPublished.SetBounds(M, UIScale(Self, 17), UIScale(Self, 320), UIScale(Self, 20));
  FLblLastPublished.Anchors := [akLeft, akTop, akRight];

  FBtnClose := TButton.Create(Self);
  FBtnClose.Parent := FFooterPanel;
  FBtnClose.SetBounds(Width - M - UIScale(Self, 96), UIScale(Self, 10),
    UIScale(Self, 96), UIScale(Self, 32));
  FBtnClose.Anchors := [akTop, akRight];
  FBtnClose.Caption := 'Close';
  FBtnClose.OnClick := @CloseClick;

  FBtnPublish := TButton.Create(Self);
  FBtnPublish.Parent := FFooterPanel;
  FBtnPublish.SetBounds(FBtnClose.Left - UIScale(Self, 128), UIScale(Self, 10),
    UIScale(Self, 120), UIScale(Self, 32));
  FBtnPublish.Anchors := [akTop, akRight];
  FBtnPublish.Caption := 'Publish Now';
  FBtnPublish.Default := True;
  FBtnPublish.OnClick := @PublishClick;

  FBtnSave := TButton.Create(Self);
  FBtnSave.Parent := FFooterPanel;
  FBtnSave.SetBounds(FBtnPublish.Left - UIScale(Self, 120), UIScale(Self, 10),
    UIScale(Self, 112), UIScale(Self, 32));
  FBtnSave.Anchors := [akTop, akRight];
  FBtnSave.Caption := 'Save Settings';
  FBtnSave.OnClick := @SaveClick;

  FPageControl := TPageControl.Create(Self);
  FPageControl.Parent := Self;
  FPageControl.Align := alClient;
  FPageControl.BorderSpacing.Around := M;
  FPageControl.OnChange := @PageControlChangeHandler;

  FTabPublish := TTabSheet.Create(FPageControl);
  FTabPublish.PageControl := FPageControl;
  FTabPublish.Caption := 'Publish';

  FTabConnection := TTabSheet.Create(FPageControl);
  FTabConnection.PageControl := FPageControl;
  FTabConnection.Caption := 'GitHub Connection & Timotheos';

  PW := Width - M * 3 - UIScale(Self, 12);

  { ---- Tab 1: Publish ---- }
  FGrpRepo := TGroupBox.Create(Self);
  FGrpRepo.Parent := FTabPublish;
  FGrpRepo.Caption := 'Linked GitHub Repository';
  FGrpRepo.SetBounds(M, UIScale(Self, 8), PW - M, UIScale(Self, 82));
  FGrpRepo.Anchors := [akLeft, akTop, akRight];

  FLblRepo := TLabel.Create(Self);
  FLblRepo.Parent := FGrpRepo;
  FLblRepo.Caption := 'Repository URL:';
  FLblRepo.SetBounds(M, UIScale(Self, 14), UIScale(Self, 110), UIScale(Self, 20));

  FEditRepoUrl := TEdit.Create(Self);
  FEditRepoUrl.Parent := FGrpRepo;
  FEditRepoUrl.SetBounds(UIScale(Self, 128), UIScale(Self, 10),
    FGrpRepo.Width - UIScale(Self, 142), UIScale(Self, 26));
  FEditRepoUrl.Anchors := [akLeft, akTop, akRight];
  FEditRepoUrl.TextHint := 'https://github.com/SalitaNgDiyos/Ang-Malayang-Biblia-Translation';
  FEditRepoUrl.OnChange := @RefreshPreviews;

  FLblTokenBadge := TLabel.Create(Self);
  FLblTokenBadge.Parent := FGrpRepo;
  FLblTokenBadge.SetBounds(M, UIScale(Self, 42), FGrpRepo.Width - M * 2, UIScale(Self, 20));
  FLblTokenBadge.Anchors := [akLeft, akTop, akRight];

  FGrpContent := TGroupBox.Create(Self);
  FGrpContent.Parent := FTabPublish;
  FGrpContent.Caption := 'What to Export & Publish';
  FGrpContent.SetBounds(M, FGrpRepo.Top + FGrpRepo.Height + UIScale(Self, 8),
    PW - M, UIScale(Self, 134));
  FGrpContent.Anchors := [akLeft, akTop, akRight];

  FLblTextKind := TLabel.Create(Self);
  FLblTextKind.Parent := FGrpContent;
  FLblTextKind.Caption := 'Text to publish:';
  FLblTextKind.SetBounds(M, UIScale(Self, 12), UIScale(Self, 110), UIScale(Self, 20));

  FComboTextKind := TComboBox.Create(Self);
  FComboTextKind.Parent := FGrpContent;
  FComboTextKind.Style := csDropDownList;
  FComboTextKind.Items.Add('Destination text (tagged with Strong''s & morphology)');
  FComboTextKind.Items.Add('Source text (interlinear)');
  FComboTextKind.Items.Add('Source text (plain)');
  FComboTextKind.SetBounds(UIScale(Self, 128), UIScale(Self, 8),
    FGrpContent.Width - UIScale(Self, 360), UIScale(Self, 26));
  FComboTextKind.Anchors := [akLeft, akTop, akRight];
  FComboTextKind.OnChange := @RefreshPreviews;

  FLblBaseName := TLabel.Create(Self);
  FLblBaseName.Parent := FGrpContent;
  FLblBaseName.Caption := 'File name base:';
  FLblBaseName.SetBounds(FGrpContent.Width - UIScale(Self, 220), UIScale(Self, 12),
    UIScale(Self, 100), UIScale(Self, 20));
  FLblBaseName.Anchors := [akTop, akRight];

  FEditBaseName := TEdit.Create(Self);
  FEditBaseName.Parent := FGrpContent;
  FEditBaseName.SetBounds(FGrpContent.Width - UIScale(Self, 118), UIScale(Self, 8),
    UIScale(Self, 104), UIScale(Self, 26));
  FEditBaseName.Anchors := [akTop, akRight];
  FEditBaseName.TextHint := 'amb+';
  FEditBaseName.OnChange := @RefreshPreviews;

  FLblFormats := TLabel.Create(Self);
  FLblFormats.Parent := FGrpContent;
  FLblFormats.Caption := 'Formats:';
  FLblFormats.SetBounds(M, UIScale(Self, 44), UIScale(Self, 110), UIScale(Self, 20));

  FCbFmtTheWord := TCheckBox.Create(Self);
  FCbFmtTheWord.Parent := FGrpContent;
  FCbFmtTheWord.Caption := 'theWord (.nt / .ot / .ont)';
  FCbFmtTheWord.SetBounds(UIScale(Self, 128), UIScale(Self, 42), UIScale(Self, 180), UIScale(Self, 24));
  FCbFmtTheWord.OnClick := @RefreshPreviews;

  FCbFmtUsfmZip := TCheckBox.Create(Self);
  FCbFmtUsfmZip.Parent := FGrpContent;
  FCbFmtUsfmZip.Caption := 'USFM 3.0 (.usfm.zip)';
  FCbFmtUsfmZip.SetBounds(UIScale(Self, 316), UIScale(Self, 42), UIScale(Self, 166), UIScale(Self, 24));
  FCbFmtUsfmZip.OnClick := @RefreshPreviews;

  FCbFmtESwordBbli := TCheckBox.Create(Self);
  FCbFmtESwordBbli.Parent := FGrpContent;
  FCbFmtESwordBbli.Caption := 'e-Sword 11+ (.bbli)';
  FCbFmtESwordBbli.SetBounds(UIScale(Self, 490), UIScale(Self, 42), UIScale(Self, 170), UIScale(Self, 24));
  FCbFmtESwordBbli.OnClick := @RefreshPreviews;

  FLblPreview := TLabel.Create(Self);
  FLblPreview.Parent := FGrpContent;
  FLblPreview.SetBounds(M, UIScale(Self, 74), FGrpContent.Width - M * 2, UIScale(Self, 32));
  FLblPreview.Anchors := [akLeft, akTop, akRight];
  FLblPreview.AutoSize := False;
  FLblPreview.WordWrap := True;

  FGrpTargets := TGroupBox.Create(Self);
  FGrpTargets.Parent := FTabPublish;
  FGrpTargets.Caption := 'Where to Publish';
  FGrpTargets.SetBounds(M, FGrpContent.Top + FGrpContent.Height + UIScale(Self, 8),
    PW - M, UIScale(Self, 134));
  FGrpTargets.Anchors := [akLeft, akTop, akRight];

  FCbUpdateRelease := TCheckBox.Create(Self);
  FCbUpdateRelease.Parent := FGrpTargets;
  FCbUpdateRelease.Caption := 'Update GitHub Release';
  FCbUpdateRelease.SetBounds(M, UIScale(Self, 10), UIScale(Self, 190), UIScale(Self, 24));
  FCbUpdateRelease.OnClick := @RefreshPreviews;

  FLblReleaseTag := TLabel.Create(Self);
  FLblReleaseTag.Parent := FGrpTargets;
  FLblReleaseTag.Caption := 'Release tag (blank = latest):';
  FLblReleaseTag.SetBounds(UIScale(Self, 214), UIScale(Self, 13), UIScale(Self, 180), UIScale(Self, 20));

  FEditReleaseTag := TEdit.Create(Self);
  FEditReleaseTag.Parent := FGrpTargets;
  FEditReleaseTag.SetBounds(UIScale(Self, 398), UIScale(Self, 9),
    FGrpTargets.Width - UIScale(Self, 412), UIScale(Self, 26));
  FEditReleaseTag.Anchors := [akLeft, akTop, akRight];
  FEditReleaseTag.TextHint := '(auto: latest release)';
  FEditReleaseTag.OnChange := @RefreshPreviews;

  FCbCommitBranch := TCheckBox.Create(Self);
  FCbCommitBranch.Parent := FGrpTargets;
  FCbCommitBranch.Caption := 'Also commit file(s) to branch:';
  FCbCommitBranch.SetBounds(M, UIScale(Self, 42), UIScale(Self, 198), UIScale(Self, 24));
  FCbCommitBranch.OnClick := @RefreshPreviews;

  FEditBranchName := TEdit.Create(Self);
  FEditBranchName.Parent := FGrpTargets;
  FEditBranchName.SetBounds(UIScale(Self, 214), UIScale(Self, 40), UIScale(Self, 136), UIScale(Self, 26));
  FEditBranchName.TextHint := '(default branch)';

  FLblBranchFolder := TLabel.Create(Self);
  FLblBranchFolder.Parent := FGrpTargets;
  FLblBranchFolder.Caption := 'Folder:';
  FLblBranchFolder.SetBounds(UIScale(Self, 360), UIScale(Self, 44), UIScale(Self, 48), UIScale(Self, 20));

  FEditBranchFolder := TEdit.Create(Self);
  FEditBranchFolder.Parent := FGrpTargets;
  FEditBranchFolder.SetBounds(UIScale(Self, 412), UIScale(Self, 40),
    FGrpTargets.Width - UIScale(Self, 426), UIScale(Self, 26));
  FEditBranchFolder.Anchors := [akLeft, akTop, akRight];
  FEditBranchFolder.TextHint := '(repo root)';

  FCbTimotheos := TCheckBox.Create(Self);
  FCbTimotheos.Parent := FGrpTargets;
  FCbTimotheos.Caption := 'Push updated Bible to Timotheos app (real-time update for PC & Android users)';
  FCbTimotheos.SetBounds(M, UIScale(Self, 74), FGrpTargets.Width - M * 2, UIScale(Self, 24));
  FCbTimotheos.Anchors := [akLeft, akTop, akRight];
  FCbTimotheos.OnClick := @RefreshPreviews;

  FLblTimotheosSummary := TLabel.Create(Self);
  FLblTimotheosSummary.Parent := FGrpTargets;
  FLblTimotheosSummary.SetBounds(UIScale(Self, 32), UIScale(Self, 98),
    FGrpTargets.Width - UIScale(Self, 46), UIScale(Self, 20));
  FLblTimotheosSummary.Anchors := [akLeft, akTop, akRight];

  FLblCommitMsg := TLabel.Create(Self);
  FLblCommitMsg.Parent := FTabPublish;
  FLblCommitMsg.Caption := 'Commit / Release Note (optional):';
  FLblCommitMsg.SetBounds(M, FGrpTargets.Top + FGrpTargets.Height + UIScale(Self, 10),
    UIScale(Self, 210), UIScale(Self, 20));

  FEditCommitMsg := TEdit.Create(Self);
  FEditCommitMsg.Parent := FTabPublish;
  FEditCommitMsg.SetBounds(UIScale(Self, 224), FGrpTargets.Top + FGrpTargets.Height + UIScale(Self, 6),
    PW - M - UIScale(Self, 224), UIScale(Self, 26));
  FEditCommitMsg.Anchors := [akLeft, akTop, akRight];
  FEditCommitMsg.TextHint := 'e.g. Updated Matthew & Mark Strong''s tags and wording';

  FProgressBar := TProgressBar.Create(Self);
  FProgressBar.Parent := FTabPublish;
  FProgressBar.SetBounds(M, FEditCommitMsg.Top + FEditCommitMsg.Height + UIScale(Self, 8),
    PW - M, UIScale(Self, 16));
  FProgressBar.Anchors := [akLeft, akTop, akRight];
  FProgressBar.Visible := False;

  FMemoLog := TMemo.Create(Self);
  FMemoLog.Parent := FTabPublish;
  FMemoLog.SetBounds(M, FProgressBar.Top + FProgressBar.Height + UIScale(Self, 8),
    PW - M, UIScale(Self, 118));
  FMemoLog.Anchors := [akLeft, akTop, akRight, akBottom];
  FMemoLog.ReadOnly := True;
  FMemoLog.ScrollBars := ssVertical;

  { ---- Tab 2: GitHub Connection & Timotheos ---- }
  FGrpAuth := TGroupBox.Create(Self);
  FGrpAuth.Parent := FTabConnection;
  FGrpAuth.Caption := 'GitHub Sign-In (saved securely on this computer)';
  FGrpAuth.SetBounds(M, UIScale(Self, 8), PW - M, UIScale(Self, 210));
  FGrpAuth.Anchors := [akLeft, akTop, akRight];

  FLblAuthHelp := TLabel.Create(Self);
  FLblAuthHelp.Parent := FGrpAuth;
  FLblAuthHelp.AutoSize := False;
  FLblAuthHelp.WordWrap := True;
  FLblAuthHelp.Caption :=
    'Enter a GitHub Personal Access Token (classic token with "repo" scope, or fine-grained token with Contents: Read & Write) ' +
    'once. It is stored securely in your operating system credential store and never written inside any .bib project file. ' +
    'If GitHub CLI (gh) is installed and signed in, you can also detect it automatically.';
  FLblAuthHelp.SetBounds(M, UIScale(Self, 12), FGrpAuth.Width - M * 2, UIScale(Self, 54));
  FLblAuthHelp.Anchors := [akLeft, akTop, akRight];

  FLblToken := TLabel.Create(Self);
  FLblToken.Parent := FGrpAuth;
  FLblToken.Caption := 'GitHub Token:';
  FLblToken.SetBounds(M, UIScale(Self, 74), UIScale(Self, 100), UIScale(Self, 20));

  FEditToken := TEdit.Create(Self);
  FEditToken.Parent := FGrpAuth;
  FEditToken.PasswordChar := '*';
  FEditToken.SetBounds(UIScale(Self, 120), UIScale(Self, 70),
    FGrpAuth.Width - UIScale(Self, 370), UIScale(Self, 26));
  FEditToken.Anchors := [akLeft, akTop, akRight];
  FEditToken.TextHint := 'ghp_... or github_pat_...';

  FBtnDetectCLI := TButton.Create(Self);
  FBtnDetectCLI.Parent := FGrpAuth;
  FBtnDetectCLI.Caption := 'Detect gh CLI';
  FBtnDetectCLI.SetBounds(FGrpAuth.Width - UIScale(Self, 242), UIScale(Self, 68),
    UIScale(Self, 112), UIScale(Self, 30));
  FBtnDetectCLI.Anchors := [akTop, akRight];
  FBtnDetectCLI.OnClick := @DetectCLIClick;

  FBtnOpenTokenPage := TButton.Create(Self);
  FBtnOpenTokenPage.Parent := FGrpAuth;
  FBtnOpenTokenPage.Caption := 'Get Token...';
  FBtnOpenTokenPage.SetBounds(FGrpAuth.Width - UIScale(Self, 124), UIScale(Self, 68),
    UIScale(Self, 110), UIScale(Self, 30));
  FBtnOpenTokenPage.Anchors := [akTop, akRight];
  FBtnOpenTokenPage.OnClick := @OpenTokenPageClick;

  FBtnSaveToken := TButton.Create(Self);
  FBtnSaveToken.Parent := FGrpAuth;
  FBtnSaveToken.Caption := 'Save Token';
  FBtnSaveToken.SetBounds(M, UIScale(Self, 112), UIScale(Self, 120), UIScale(Self, 30));
  FBtnSaveToken.OnClick := @SaveTokenClick;

  FBtnClearToken := TButton.Create(Self);
  FBtnClearToken.Parent := FGrpAuth;
  FBtnClearToken.Caption := 'Clear Saved Token';
  FBtnClearToken.SetBounds(UIScale(Self, 140), UIScale(Self, 112), UIScale(Self, 146), UIScale(Self, 30));
  FBtnClearToken.OnClick := @ClearTokenClick;

  FBtnTestConn := TButton.Create(Self);
  FBtnTestConn.Parent := FGrpAuth;
  FBtnTestConn.Caption := 'Test Connection';
  FBtnTestConn.SetBounds(UIScale(Self, 294), UIScale(Self, 112), UIScale(Self, 140), UIScale(Self, 30));
  FBtnTestConn.OnClick := @TestConnClick;

  FLblConnStatus := TLabel.Create(Self);
  FLblConnStatus.Parent := FGrpAuth;
  FLblConnStatus.AutoSize := False;
  FLblConnStatus.WordWrap := True;
  FLblConnStatus.SetBounds(M, UIScale(Self, 152), FGrpAuth.Width - M * 2, UIScale(Self, 36));
  FLblConnStatus.Anchors := [akLeft, akTop, akRight];

  FGrpTimotheosCfg := TGroupBox.Create(Self);
  FGrpTimotheosCfg.Parent := FTabConnection;
  FGrpTimotheosCfg.Caption := 'Timotheos App Live Update Target';
  FGrpTimotheosCfg.SetBounds(M, FGrpAuth.Top + FGrpAuth.Height + UIScale(Self, 12),
    PW - M, UIScale(Self, 180));
  FGrpTimotheosCfg.Anchors := [akLeft, akTop, akRight];

  FLblTimRepo := TLabel.Create(Self);
  FLblTimRepo.Parent := FGrpTimotheosCfg;
  FLblTimRepo.Caption := 'Timotheos Repo URL:';
  FLblTimRepo.SetBounds(M, UIScale(Self, 16), UIScale(Self, 140), UIScale(Self, 20));

  FEditTimRepo := TEdit.Create(Self);
  FEditTimRepo.Parent := FGrpTimotheosCfg;
  FEditTimRepo.SetBounds(UIScale(Self, 160), UIScale(Self, 12),
    FGrpTimotheosCfg.Width - UIScale(Self, 174), UIScale(Self, 26));
  FEditTimRepo.Anchors := [akLeft, akTop, akRight];
  FEditTimRepo.OnChange := @RefreshPreviews;

  FLblTimBranch := TLabel.Create(Self);
  FLblTimBranch.Parent := FGrpTimotheosCfg;
  FLblTimBranch.Caption := 'Target Branch:';
  FLblTimBranch.SetBounds(M, UIScale(Self, 50), UIScale(Self, 140), UIScale(Self, 20));

  FEditTimBranch := TEdit.Create(Self);
  FEditTimBranch.Parent := FGrpTimotheosCfg;
  FEditTimBranch.SetBounds(UIScale(Self, 160), UIScale(Self, 46), UIScale(Self, 160), UIScale(Self, 26));
  FEditTimBranch.OnChange := @RefreshPreviews;

  FLblTimPath := TLabel.Create(Self);
  FLblTimPath.Parent := FGrpTimotheosCfg;
  FLblTimPath.Caption := 'Bundled File Path:';
  FLblTimPath.SetBounds(M, UIScale(Self, 84), UIScale(Self, 140), UIScale(Self, 20));

  FEditTimPath := TEdit.Create(Self);
  FEditTimPath.Parent := FGrpTimotheosCfg;
  FEditTimPath.SetBounds(UIScale(Self, 160), UIScale(Self, 80),
    FGrpTimotheosCfg.Width - UIScale(Self, 174), UIScale(Self, 26));
  FEditTimPath.Anchors := [akLeft, akTop, akRight];
  FEditTimPath.OnChange := @RefreshPreviews;

  FCbTimSkipCI := TCheckBox.Create(Self);
  FCbTimSkipCI.Parent := FGrpTimotheosCfg;
  FCbTimSkipCI.Caption := 'Add [skip ci] when committing bundled Bible to Timotheos (live auto-update still runs immediately for users)';
  FCbTimSkipCI.SetBounds(M, UIScale(Self, 118), FGrpTimotheosCfg.Width - M * 2, UIScale(Self, 24));
  FCbTimSkipCI.Anchors := [akLeft, akTop, akRight];
end;

procedure TGitHubPublishForm.ApplyTheme;
  procedure EnsureHandles(W: TWinControl);
  var
    I: Integer;
  begin
    if not Assigned(W) then Exit;
    W.HandleNeeded;
    for I := 0 to W.ControlCount - 1 do
      if W.Controls[I] is TWinControl then
        EnsureHandles(TWinControl(W.Controls[I]));
  end;
begin
  ApplyDialogStyle(Self);
  StyleControl(FFooterPanel, uirFooter);
  StyleControl(FLblTokenBadge, uirHint);
  StyleControl(FLblPreview, uirHint);
  StyleControl(FLblTimotheosSummary, uirHint);
  StyleControl(FLblAuthHelp, uirHint);
  StyleControl(FLblLastPublished, uirHint);
  if Assigned(FMemoLog) then
  begin
    FMemoLog.Color := UIContentColor;
    FMemoLog.Font.Color := UITextColor;
    FMemoLog.Font.Name := UIMonoFontName;
    FMemoLog.Font.Size := 9;
  end;
  if HandleAllocated and (Visible or Showing) then
  begin
    if Assigned(FPageControl) and Assigned(FPageControl.ActivePage) then
      EnsureHandles(FPageControl.ActivePage);
    ApplyDarkModeToWindow(Self, CurrentSkin.IsDark);
    ApplySkinToForm(Self, CurrentSkin);
  end;
  RefreshTokenStatusBadge;
end;

procedure TGitHubPublishForm.LoadFromProject;
var
  Link: TGitHubProjectLink;
  SavedTok, SourceLbl: string;
begin
  Link := LoadGitHubProjectLink(FProject);
  FEditRepoUrl.Text := Link.RepoUrl;
  FComboTextKind.ItemIndex := Ord(Link.TextKind);
  FEditBaseName.Text := Link.BaseFileName;
  FCbFmtTheWord.Checked := Link.PublishTheWord;
  FCbFmtUsfmZip.Checked := Link.PublishUSFMZip;
  FCbFmtESwordBbli.Checked := Link.PublishESwordBbli;
  FCbUpdateRelease.Checked := Link.UpdateRelease;
  FEditReleaseTag.Text := Link.ReleaseTag;
  FCbCommitBranch.Checked := Link.CommitToBranch;
  FEditBranchName.Text := Link.BranchName;
  FEditBranchFolder.Text := Link.BranchFolder;
  FCbTimotheos.Checked := Link.TimotheosEnabled;

  FEditTimRepo.Text := Link.TimotheosRepoUrl;
  FEditTimBranch.Text := Link.TimotheosBranch;
  FEditTimPath.Text := Link.TimotheosFilePath;
  FCbTimSkipCI.Checked := Link.TimotheosSkipCI;

  SavedTok := LoadSavedGitHubToken(FIni);
  if SavedTok <> '' then
    FEditToken.Text := SavedTok
  else if ResolveGitHubToken(FIni, SourceLbl) <> '' then
    FLblConnStatus.Caption := 'Detected active login via ' + SourceLbl + '. Ready to publish.';

  if Link.LastPublishedAt <> '' then
    FLblLastPublished.Caption := 'Last published: ' + Link.LastPublishedAt
  else
    FLblLastPublished.Caption := 'Not published from iBiblia yet.';

  RefreshPreviews(nil);
  RefreshTokenStatusBadge;
end;

function TGitHubPublishForm.CollectLinkFromUI: TGitHubProjectLink;
begin
  Result := DefaultGitHubProjectLink(FProject);
  Result.RepoUrl := NormalizeGitHubRepoUrl(FEditRepoUrl.Text);
  if (FComboTextKind.ItemIndex >= 0) and (FComboTextKind.ItemIndex <= Ord(ghtSourcePlain)) then
    Result.TextKind := TGitHubTextKind(FComboTextKind.ItemIndex);
  Result.BaseFileName := Trim(FEditBaseName.Text);
  Result.PublishTheWord := FCbFmtTheWord.Checked;
  Result.PublishUSFMZip := FCbFmtUsfmZip.Checked;
  Result.PublishESwordBbli := FCbFmtESwordBbli.Checked;
  Result.UpdateRelease := FCbUpdateRelease.Checked;
  Result.ReleaseTag := Trim(FEditReleaseTag.Text);
  Result.CommitToBranch := FCbCommitBranch.Checked;
  Result.BranchName := Trim(FEditBranchName.Text);
  Result.BranchFolder := Trim(FEditBranchFolder.Text);
  Result.TimotheosEnabled := FCbTimotheos.Checked;
  Result.TimotheosRepoUrl := NormalizeGitHubRepoUrl(FEditTimRepo.Text);
  if Result.TimotheosRepoUrl = '' then
    Result.TimotheosRepoUrl := GITHUB_DEFAULT_TIMOTHEOS_REPO;
  Result.TimotheosBranch := Trim(FEditTimBranch.Text);
  if Result.TimotheosBranch = '' then
    Result.TimotheosBranch := GITHUB_DEFAULT_TIMOTHEOS_BRANCH;
  Result.TimotheosFilePath := Trim(FEditTimPath.Text);
  if Result.TimotheosFilePath = '' then
    Result.TimotheosFilePath := GITHUB_DEFAULT_TIMOTHEOS_PATH;
  Result.TimotheosSkipCI := FCbTimSkipCI.Checked;
end;

procedure TGitHubPublishForm.RefreshTokenStatusBadge;
var
  Tok, SourceLbl, RepoOwner, RepoName: string;
  HasRepo: Boolean;
begin
  Tok := Trim(FEditToken.Text);
  if Tok <> '' then
    SourceLbl := 'GitHub token ready'
  else
  begin
    Tok := ResolveGitHubToken(FIni, SourceLbl);
    if Tok <> '' then
      SourceLbl := 'Signed in via ' + SourceLbl;
  end;

  HasRepo := ParseGitHubOwnerRepo(FEditRepoUrl.Text, RepoOwner, RepoName);
  if Tok = '' then
  begin
    FLblTokenBadge.Caption := 'Not signed in yet — go to "GitHub Connection & Timotheos" to save a token.';
    FLblTokenBadge.Font.Color := UIWarningTextColor;
  end
  else if HasRepo then
  begin
    FLblTokenBadge.Caption := Format('%s · Target repo: %s/%s', [SourceLbl, RepoOwner, RepoName]);
    FLblTokenBadge.Font.Color := UISuccessTextColor;
  end
  else
  begin
    FLblTokenBadge.Caption := Format('%s · Enter your GitHub repository URL above (e.g. https://github.com/owner/repo).', [SourceLbl]);
    FLblTokenBadge.Font.Color := UITextColor;
  end;
end;

procedure TGitHubPublishForm.RefreshPreviews(Sender: TObject);
var
  Base, Ext, FilesStr, TimRepo, TimBranch, TimPath: string;
begin
  Base := Trim(FEditBaseName.Text);
  if Base = '' then Base := 'module';
  if Assigned(FProject) then
    Ext := ScopeTheWordExtension(FProject.Escopo)
  else
    Ext := '.nt';

  FilesStr := '';
  if FCbFmtTheWord.Checked then FilesStr := FilesStr + Base + Ext + '   ';
  if FCbFmtUsfmZip.Checked then FilesStr := FilesStr + Base + '.usfm.zip   ';
  if FCbFmtESwordBbli.Checked then FilesStr := FilesStr + Base + '.bbli';
  if Trim(FilesStr) = '' then
    FilesStr := '(none selected — select at least one format above)';
  FLblPreview.Caption := 'Files to publish: ' + Trim(FilesStr);

  FEditReleaseTag.Enabled := FCbUpdateRelease.Checked;
  FEditBranchName.Enabled := FCbCommitBranch.Checked;
  FEditBranchFolder.Enabled := FCbCommitBranch.Checked;

  TimRepo := Trim(FEditTimRepo.Text);
  if TimRepo = '' then TimRepo := GITHUB_DEFAULT_TIMOTHEOS_REPO;
  TimBranch := Trim(FEditTimBranch.Text);
  if TimBranch = '' then TimBranch := GITHUB_DEFAULT_TIMOTHEOS_BRANCH;
  TimPath := Trim(FEditTimPath.Text);
  if TimPath = '' then TimPath := GITHUB_DEFAULT_TIMOTHEOS_PATH;
  FLblTimotheosSummary.Caption := Format('Target: %s (branch %s) -> %s',
    [TimRepo, TimBranch, TimPath]);
  FLblTimotheosSummary.Enabled := FCbTimotheos.Checked;

  RefreshTokenStatusBadge;
end;

procedure TGitHubPublishForm.AppendLog(const Msg: string);
begin
  if not Assigned(FMemoLog) then Exit;
  FMemoLog.Lines.Add('[' + FormatDateTime('hh:nn:ss', Now) + '] ' + Msg);
end;

procedure TGitHubPublishForm.SetControlsEnabledForPublish(Idle: Boolean);
begin
  FPageControl.Enabled := Idle;
  FBtnSave.Enabled := Idle;
  FBtnPublish.Enabled := Idle;
  FBtnClose.Enabled := Idle;
end;

procedure TGitHubPublishForm.FormShowHandler(Sender: TObject);
begin
  ApplyTheme;
end;

procedure TGitHubPublishForm.PageControlChangeHandler(Sender: TObject);
begin
  ApplyTheme;
end;

procedure TGitHubPublishForm.FormCloseQueryHandler(Sender: TObject;
  var CanClose: Boolean);
begin
  CanClose := not FPublishing;
end;

procedure TGitHubPublishForm.SaveClick(Sender: TObject);
var
  Link: TGitHubProjectLink;
  RepoOwner, RepoName: string;
begin
  Link := CollectLinkFromUI;
  if (Link.RepoUrl <> '') and (not ParseGitHubOwnerRepo(Link.RepoUrl, RepoOwner, RepoName)) then
  begin
    MessageDlg(Caption, 'Please enter a valid GitHub repository URL (e.g. https://github.com/owner/repo).',
      mtWarning, [mbOK], 0);
    FEditRepoUrl.SetFocus;
    Exit;
  end;
  SaveGitHubProjectLink(FProject, Link);
  FSettingsSaved := True;
  AppendLog('Project GitHub publishing settings saved.');
end;

procedure TGitHubPublishForm.DetectCLIClick(Sender: TObject);
var
  Tok: string;
begin
  if TryDetectGitHubCLIToken(Tok) then
  begin
    FEditToken.Text := Tok;
    FLblConnStatus.Caption := 'Detected GitHub token from gh CLI. Click "Save Token" to keep it saved.';
    FLblConnStatus.Font.Color := UISuccessTextColor;
    RefreshTokenStatusBadge;
  end
  else
  begin
    FLblConnStatus.Caption := 'GitHub CLI (gh) was not found or is not signed in. Paste a token or click "Get Token...".';
    FLblConnStatus.Font.Color := UIWarningTextColor;
  end;
end;

procedure TGitHubPublishForm.OpenTokenPageClick(Sender: TObject);
begin
  OpenURL('https://github.com/settings/tokens/new?scopes=repo&description=Dark-Skinned-iBiblia');
end;

procedure TGitHubPublishForm.SaveTokenClick(Sender: TObject);
var
  Tok: string;
begin
  Tok := Trim(FEditToken.Text);
  if Tok = '' then
  begin
    MessageDlg(Caption, 'Paste a GitHub token first (or click Clear Saved Token to remove it).',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  SaveGitHubToken(FIni, Tok);
  FLblConnStatus.Caption := 'GitHub token saved securely in your system credential store.';
  FLblConnStatus.Font.Color := UISuccessTextColor;
  RefreshTokenStatusBadge;
end;

procedure TGitHubPublishForm.ClearTokenClick(Sender: TObject);
begin
  ClearGitHubToken(FIni);
  FEditToken.Text := '';
  FLblConnStatus.Caption := 'Saved GitHub token cleared.';
  FLblConnStatus.Font.Color := UITextColor;
  RefreshTokenStatusBadge;
end;

procedure TGitHubPublishForm.TestConnClick(Sender: TObject);
var
  Tok, SourceLbl, RepoOwner, RepoName, Login, DefBranch, LatestTag, ErrMsg: string;
begin
  Tok := Trim(FEditToken.Text);
  if Tok = '' then
    Tok := ResolveGitHubToken(FIni, SourceLbl);
  ParseGitHubOwnerRepo(FEditRepoUrl.Text, RepoOwner, RepoName);

  Screen.Cursor := crHourGlass;
  try
    if TestGitHubConnection(Tok, RepoOwner, RepoName, Login, DefBranch, LatestTag, ErrMsg) then
    begin
      if RepoOwner <> '' then
        FLblConnStatus.Caption := Format('Connected as %s · %s/%s (branch: %s, latest release: %s)',
          [Login, RepoOwner, RepoName, DefBranch, LatestTag])
      else
        FLblConnStatus.Caption := Format('Connected to GitHub as %s.', [Login]);
      FLblConnStatus.Font.Color := UISuccessTextColor;
    end
    else
    begin
      FLblConnStatus.Caption := 'Connection test failed: ' + ErrMsg;
      FLblConnStatus.Font.Color := UIErrorTextColor;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TGitHubPublishForm.PublishClick(Sender: TObject);
var
  Link: TGitHubProjectLink;
  Tok, SourceLbl, RepoOwner, RepoName, TheWordFile, ErrMsg: string;
  ExportedFiles: TStringList;
begin
  if FPublishing then Exit;

  Link := CollectLinkFromUI;
  if not (Link.UpdateRelease or Link.CommitToBranch or Link.TimotheosEnabled) then
  begin
    MessageDlg(Caption, 'Enable at least one publish target: Update GitHub Release, Commit to branch, or Timotheos app.',
      mtWarning, [mbOK], 0);
    Exit;
  end;

  if (Link.UpdateRelease or Link.CommitToBranch) and
     (not ParseGitHubOwnerRepo(Link.RepoUrl, RepoOwner, RepoName)) then
  begin
    MessageDlg(Caption, 'Enter the linked GitHub repository URL (e.g. https://github.com/SalitaNgDiyos/Ang-Malayang-Biblia-Translation).',
      mtWarning, [mbOK], 0);
    FEditRepoUrl.SetFocus;
    Exit;
  end;

  if (Link.UpdateRelease or Link.CommitToBranch) and
     not (Link.PublishTheWord or Link.PublishUSFMZip or Link.PublishESwordBbli) then
  begin
    MessageDlg(Caption, 'Select at least one Bible format to export and publish (.nt/.ot/.ont, .usfm.zip, or .bbli).',
      mtWarning, [mbOK], 0);
    Exit;
  end;

  Tok := Trim(FEditToken.Text);
  if Tok = '' then
    Tok := ResolveGitHubToken(FIni, SourceLbl);
  if Tok = '' then
  begin
    MessageDlg(Caption, 'Please enter and save a GitHub token (or sign in with GitHub CLI) on the GitHub Connection tab.',
      mtWarning, [mbOK], 0);
    FPageControl.ActivePage := FTabConnection;
    ApplyTheme;
    Exit;
  end;

  // Save token if user typed one that wasn't saved yet
  if (Trim(FEditToken.Text) <> '') and (LoadSavedGitHubToken(FIni) <> Trim(FEditToken.Text)) then
    SaveGitHubToken(FIni, Trim(FEditToken.Text));

  SaveGitHubProjectLink(FProject, Link);
  FSettingsSaved := True;

  FMemoLog.Clear;
  AppendLog('Exporting Bible module file(s)...');
  SetControlsEnabledForPublish(False);
  FPublishing := True;
  FProgressBar.Visible := True;
  Application.ProcessMessages;

  if (FTempDir <> '') and DirectoryExists(FTempDir) then
    DeleteDirectory(FTempDir, False);
  FTempDir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'ibiblia-gh-' + IntToStr(GetTickCount64);

  ExportedFiles := TStringList.Create;
  try
    if not ExportProjectFilesForGitHub(FProject, Link, FTempDir, FProgressBar,
         ExportedFiles, TheWordFile, ErrMsg) then
    begin
      FPublishing := False;
      FProgressBar.Visible := False;
      SetControlsEnabledForPublish(True);
      AppendLog('Export failed: ' + ErrMsg);
      MessageDlg(Caption, 'Export failed: ' + ErrMsg, mtError, [mbOK], 0);
      Exit;
    end;

    AppendLog(Format('Export complete (%d file(s) staged). Uploading to GitHub...',
      [Max(ExportedFiles.Count, Ord(TheWordFile <> ''))]));
    FProgressBar.Visible := True;
    FProgressBar.Style := pbstMarquee;

    if Assigned(FWorker) then
    begin
      FWorker.WaitFor;
      FreeAndNil(FWorker);
    end;
    FWorker := TGitHubPublishWorker.Create(Self, Tok, Link, ExportedFiles,
      TheWordFile, Trim(FEditCommitMsg.Text));
    FWorker.Start;
  finally
    ExportedFiles.Free;
  end;
end;

procedure TGitHubPublishForm.WorkerFinished(ASuccess: Boolean;
  const ASummary, AErrMsg: string; const APublishedLink: TGitHubProjectLink);
var
  UpdatedLink: TGitHubProjectLink;
  Stamp: string;
begin
  FPublishing := False;
  FProgressBar.Style := pbstNormal;
  FProgressBar.Visible := False;
  SetControlsEnabledForPublish(True);

  if (FTempDir <> '') and DirectoryExists(FTempDir) then
  begin
    DeleteDirectory(FTempDir, False);
    FTempDir := '';
  end;

  if ASuccess then
  begin
    Stamp := FormatDateTime('yyyy-mm-dd hh:nn', Now);
    UpdatedLink := APublishedLink;
    UpdatedLink.LastPublishedAt := Stamp;
    UpdatedLink.LastPublishSummary := Trim(ASummary);
    SaveGitHubProjectLink(FProject, UpdatedLink);
    FLblLastPublished.Caption := 'Last published: ' + Stamp;
    RecordProjectChange(FProject.FileName, 'GitHub',
      'Published module to GitHub', Trim(ASummary));
    AppendLog('DONE! Published successfully:');
    FMemoLog.Lines.Add(Trim(ASummary));
    MessageDlg(Caption, 'Published to GitHub successfully!' + LineEnding + LineEnding +
      Trim(ASummary), mtInformation, [mbOK], 0);
  end
  else
  begin
    AppendLog('Publish failed: ' + AErrMsg);
    MessageDlg(Caption, 'Publish failed: ' + AErrMsg, mtError, [mbOK], 0);
  end;
end;

procedure TGitHubPublishForm.CloseClick(Sender: TObject);
begin
  if not FPublishing then
    Close;
end;

end.
