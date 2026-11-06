unit tls_runtime;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpclient, ssockets;

const
  {$IFDEF WINDOWS}
  TLS_SSL_FILE_NAME = 'libssl-3-x64.dll';
  TLS_CRYPTO_FILE_NAME = 'libcrypto-3-x64.dll';
  {$ELSE}
  TLS_SSL_FILE_NAME = 'libssl.so.3';
  TLS_CRYPTO_FILE_NAME = 'libcrypto.so.3';
  {$ENDIF}
  TLS_CA_FILE_NAME = 'cacert.pem';

type
  ETLSRuntimeError = class(Exception);
  ETLSCertificateError = class(ETLSRuntimeError)
  private
    FVerificationCode: Integer;
  public
    constructor Create(AVerificationCode: Integer);
    property VerificationCode: Integer read FVerificationCode;
  end;

  TIBibliaHTTPSClient = class(TFPHTTPClient)
  private
    FRuntimeDirectory: string;
  protected
    function GetSocketHandler(const UseSSL: Boolean): TSocketHandler; override;
  public
    constructor Create(AOwner: TComponent); override;
    constructor CreateForRuntime(AOwner: TComponent;
      const ARuntimeDirectory: string);
  end;

procedure EnsureBundledTLSInitialized(const RuntimeDirectory: string = '');
function BundledTLSVersion: string;

implementation

uses
  syncobjs, openssl, opensslsockets;

type
  TVerifiedSocketHandler = class(TOpenSSLSocketHandler)
  public
    function Connect: Boolean; override;
  end;

var
  InitializationLock: TCriticalSection;
  LoadedRuntimeDirectory: string;
  LoadedCAFileName: string;

function NormalizeRuntimeDirectory(const Value: string): string;
begin
  if Value = '' then
    Result := ExtractFilePath(ParamStr(0))
  else
    Result := Value;
  Result := IncludeTrailingPathDelimiter(ExpandFileName(Result));
end;

function ResolveCAFileName(const DirectoryName: string): string;
{$IFNDEF WINDOWS}
const
  SystemCABundles: array[0..4] of string = (
    '/etc/ssl/certs/ca-certificates.crt',
    '/etc/pki/tls/certs/ca-bundle.crt',
    '/etc/ssl/ca-bundle.pem',
    '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem',
    '/etc/ssl/cert.pem'
  );
var
  Candidate: string;
{$ENDIF}
begin
  Result := DirectoryName + TLS_CA_FILE_NAME;
  if FileExists(Result) then
    Exit;
  {$IFNDEF WINDOWS}
  for Candidate in SystemCABundles do
    if FileExists(Candidate) then
      Exit(Candidate);
  {$ENDIF}
end;

constructor ETLSCertificateError.Create(AVerificationCode: Integer);
begin
  FVerificationCode := AVerificationCode;
  inherited CreateFmt(
    'The HTTPS certificate or server name could not be verified (code %d).',
    [AVerificationCode]);
end;

procedure EnsureBundledTLSInitialized(const RuntimeDirectory: string);
var
  DirectoryName, SSLFileName, CryptoFileName, CAFile: string;
  {$IFDEF WINDOWS}
  RequiredFile: string;
  {$ENDIF}
begin
  DirectoryName := NormalizeRuntimeDirectory(RuntimeDirectory);
  InitializationLock.Enter;
  try
    if LoadedRuntimeDirectory <> '' then
    begin
      {$IFDEF WINDOWS}
      if not SameFileName(DirectoryName, LoadedRuntimeDirectory) then
        raise ETLSRuntimeError.Create(
          'TLS is already initialized from another runtime directory.');
      {$ENDIF}
      Exit;
    end;
    SSLFileName := DirectoryName + TLS_SSL_FILE_NAME;
    CryptoFileName := DirectoryName + TLS_CRYPTO_FILE_NAME;
    CAFile := ResolveCAFileName(DirectoryName);

    {$IFDEF WINDOWS}
    for RequiredFile in [SSLFileName, CryptoFileName,
      DirectoryName + TLS_CA_FILE_NAME] do
      if not FileExists(RequiredFile) then
        raise ETLSRuntimeError.CreateFmt(
          'The HTTPS runtime file %s is missing. Extract the complete iBiblia package.',
          [ExtractFileName(RequiredFile)]);

    if IsSSLLoaded then
      raise ETLSRuntimeError.Create(
        'TLS was initialized outside the bundled iBiblia runtime.');
    if not InitSSLInterface(SSLFileName, CryptoFileName) then
      raise ETLSRuntimeError.Create(
        'The bundled HTTPS libraries could not be loaded. Extract the complete Windows x64 package.');
    if (Pos('OpenSSL 3.5.', OpenSSLGetVersion(0)) <> 1) or
       (SslLibraryInit <> 1) then
    begin
      DestroySSLInterface;
      raise ETLSRuntimeError.Create(
        'The bundled OpenSSL 3.5 runtime could not be initialized.');
    end;
    {$ELSE}
    if not FileExists(CAFile) then
      raise ETLSRuntimeError.CreateFmt(
        'No HTTPS CA certificate bundle was found (%s or /etc/ssl/certs/ca-certificates.crt).',
        [ExtractFileName(CAFile)]);
    if not IsSSLLoaded then
    begin
      if FileExists(SSLFileName) and FileExists(CryptoFileName) then
        InitSSLInterface(SSLFileName, CryptoFileName);
      if not IsSSLLoaded then
        InitSSLInterface('libssl.so.3', 'libcrypto.so.3');
      if not IsSSLLoaded then
        InitSSLInterface('libssl.so.1.1', 'libcrypto.so.1.1');
      if not IsSSLLoaded then
        InitSSLInterface;
      if not IsSSLLoaded then
        raise ETLSRuntimeError.Create(
          'The OpenSSL libraries (libssl.so.3 / libcrypto.so.3) could not be loaded.');
    end;
    if SslLibraryInit <> 1 then
    begin
      DestroySSLInterface;
      raise ETLSRuntimeError.Create(
        'The OpenSSL runtime could not be initialized.');
    end;
    {$ENDIF}
    LoadedRuntimeDirectory := DirectoryName;
    LoadedCAFileName := CAFile;
  finally
    InitializationLock.Leave;
  end;
end;

function BundledTLSVersion: string;
begin
  if LoadedRuntimeDirectory = '' then
    Result := ''
  else
    Result := OpenSSLGetVersion(0);
end;

function TVerifiedSocketHandler.Connect: Boolean;
var
  Verification: Integer;
begin
  Result := inherited Connect;
  if not Result then
  begin
    Verification := 0;
    if Assigned(SSL) then
      Verification := SSL.VerifyResult;
    if Verification <> 0 then
      raise ETLSCertificateError.Create(Verification);
    raise ETLSRuntimeError.Create('The HTTPS connection failed: ' +
      Trim(SSLLastErrorString));
  end;
end;

constructor TIBibliaHTTPSClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRuntimeDirectory := NormalizeRuntimeDirectory('');
end;

constructor TIBibliaHTTPSClient.CreateForRuntime(AOwner: TComponent;
  const ARuntimeDirectory: string);
begin
  inherited Create(AOwner);
  FRuntimeDirectory := NormalizeRuntimeDirectory(ARuntimeDirectory);
end;

function TIBibliaHTTPSClient.GetSocketHandler(
  const UseSSL: Boolean): TSocketHandler;
var
  Handler: TVerifiedSocketHandler;
begin
  if not UseSSL then
    raise ETLSRuntimeError.Create('This connection requires HTTPS.');
  EnsureBundledTLSInitialized(FRuntimeDirectory);
  Handler := TVerifiedSocketHandler.Create;
  try
    Handler.VerifyPeerCert := True;
    Handler.SendHostAsSNI := True;
    if LoadedCAFileName <> '' then
      Handler.CertificateData.CertCA.FileName := LoadedCAFileName
    else
      Handler.CertificateData.CertCA.FileName :=
        ResolveCAFileName(FRuntimeDirectory);
    Result := Handler;
  except
    Handler.Free;
    raise;
  end;
end;

initialization
  InitializationLock := TCriticalSection.Create;

finalization
  InitializationLock.Free;

end.
