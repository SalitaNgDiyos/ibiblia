unit zzprof;
{$mode objfpc}{$H+}
interface
var
  ZZAcc: array[0..31] of Int64;
function ZZNow: Int64;
procedure ZZAdd(I: Integer; Start: Int64);
implementation
{$IFDEF WINDOWS}
uses Windows;
var Freq: Int64 = 0;
function ZZNow: Int64;
var C: Int64;
begin
  if Freq = 0 then QueryPerformanceFrequency(Freq);
  QueryPerformanceCounter(C);
  Result := C * 1000000 div Freq;
end;
{$ELSE}
uses Unix, BaseUnix;
function ZZNow: Int64;
var tv: TTimeVal;
begin
  fpgettimeofday(@tv, nil);
  Result := Int64(tv.tv_sec) * 1000000 + tv.tv_usec;
end;
{$ENDIF}
procedure ZZAdd(I: Integer; Start: Int64);
begin
  Inc(ZZAcc[I], ZZNow - Start);
end;
end.
