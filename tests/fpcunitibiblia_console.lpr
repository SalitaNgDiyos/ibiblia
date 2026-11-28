program fpcunitibiblia_console;

{$mode objfpc}{$H+}

uses
  Interfaces,
  consoletestrunner,
  fpcunit,
  fpcunitreport,
  testutils,
  unitskins,
  zz_bench,
  ibibliatest,
  versiculotest,
  syntagmselectiontest,
  statuscatalogtest,
  project_setup_validation_test,
  theword_syntax_highlighter_test,
  ai_processing_batch_test,
  ai_flow_config_test,
  ai_response_validation_test,
  ai_processing_manager_test,
  ai_credentials_test,
  ai_credential_flow_test,
  ai_global_settings_test,
  ai_effective_settings_test,
  llm_options_form_test,
  flow_examples_form_test,
  project_patch_applier_test,
  export_file_staging_test,
  export_in_use_test,
  export_sqlite_publisher_test,
  export_destination_history_test,
  project_export_form_test,
  suggestionmanagertest,
  associationmemoryservicetest,
  concordanceexporttest,
  association_highlight_projection_test,
  project_persistence_test,
  project_save_as_test,
  project_save_snapshot_test,
  project_save_as_form_test,
  navigation_history_test,
  theword_sync_state_test,
  verse_visual_adapter_test,
  verse_inline_style_projection_test,
  verse_visual_document_test,
  text_direction_test,
  text_edit_provenance_test,
  versememotest,
  theword_ont_codec_v2_test,
  theword_wysiwyg_session_v2_test,
  theword_clipboard_v2_test,
  rf_note_scanner_test,
  theword_translator_note_visual_test,
  project_exporter_integration_test,
  theword_module_encoding_test,
  theword_module_import_test,
  theword_effective_inline_style_v2_test,
  theword_effective_inline_style_v2_review_test,
  theword_font_color_mutation_v2_test,
  theword_pending_formatting_lifecycle_test,
  chapter_inline_style_projection_test,
  theword_font_size_mutation_v2_test,
  association_note_visual_projection_test,
  association_note_verse_interaction_test,
  translator_note_hover_controller_test,
  translation_memory_focus_controller_test,
  translation_memory_preview_test,
  project_creation_staging_test,
  default_verse_mode_test,
  localization_test,
  ui_identity_test,
  performance_debug_test,
  wysiwyg_editor_performance_test;

type
  { Puts every test on the same starting skin. The skin is global state that
    other tests (and the main form) change, so without this a test result can
    depend on which tests ran before it. Tests that need another skin set it
    themselves after this runs. }
  TSkinPinListener = class(TNoRefCountObject, ITestListener)
  public
    procedure AddFailure(ATest: TTest; AFailure: TTestFailure);
    procedure AddError(ATest: TTest; AError: TTestFailure);
    procedure StartTest(ATest: TTest);
    procedure EndTest(ATest: TTest);
    procedure StartTestSuite(ATestSuite: TTestSuite);
    procedure EndTestSuite(ATestSuite: TTestSuite);
  end;

  TPinnedTestRunner = class(TTestRunner)
  protected
    procedure DoTestRun(ATest: TTest); override;
  end;

procedure TSkinPinListener.AddFailure(ATest: TTest; AFailure: TTestFailure);
begin
end;

procedure TSkinPinListener.AddError(ATest: TTest; AError: TTestFailure);
begin
end;

procedure TSkinPinListener.StartTest(ATest: TTest);
begin
  SetCurrentSkin(skClassic);
end;

procedure TSkinPinListener.EndTest(ATest: TTest);
begin
end;

procedure TSkinPinListener.StartTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure TSkinPinListener.EndTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure TPinnedTestRunner.DoTestRun(ATest: TTest);
var
  ResultsWriter: TCustomResultsWriter;
  SkinPin: TSkinPinListener;
  TestResult: TTestResult;
begin
  ResultsWriter := nil;
  SkinPin := TSkinPinListener.Create;
  TestResult := TTestResult.Create;
  try
    TestResult.AddListener(SkinPin);
    ResultsWriter := GetResultsWriter;
    ResultsWriter.Filename := FileName;
    TestResult.AddListener(ResultsWriter);
    ATest.Run(TestResult);
    ResultsWriter.WriteResult(TestResult);
    if not TestResult.WasSuccessful then
      ExitCode := 1;
  finally
    TestResult.Free;
    ResultsWriter.Free;
    SkinPin.Free;
  end;
end;

var
  Application: TPinnedTestRunner;

begin
  DefaultRunAllTests := True;
  DefaultFormat := fPlain;
  Application := TPinnedTestRunner.Create(nil);
  Application.Initialize;
  Application.Title := 'iBiblia console test runner';
  Application.Run;
  Application.Free;
end.
