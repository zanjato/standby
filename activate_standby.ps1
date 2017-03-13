#requires -version 2
<#set-executionpolicy remotesigned localmachine -f
powershell.exe -nol -nop -non -f activate_standby.ps1[ -activate][ -call]#>
param([switch]$activate,[switch]$call)
set-strictmode -vers latest
&{
  function chkpars{
    param([parameter(mandatory=$true)][validatenotnull()]
          [management.automation.commandinfo]$ci,
          [parameter(mandatory=$true)][validatenotnull()]
          [collections.generic.dictionary[string,object]]$bp)
    $ci.parameters.getenumerator()|?{!$_.value.switchparameter}|
    %{gv $_.key -ea silentlycontinue}|?{!$bp.containskey($_.name)}|
    %{throw "Функция '$($ci.name)' вызвана без параметра '$($_.name)'"}
  }
  function dispose-after{[cmdletbinding()]
    param([validatenotnull()][object]$obj,[validatenotnull()][scriptblock]$sb)
    chkpars $myinvocation.mycommand $psboundparameters
    try{&$sb}
    finally{
      if($obj -is [idisposable] -or $obj -as [idisposable]){
        [void][idisposable].getmethod('Dispose').invoke($obj,$null)
      }
    }
  }
  function log{[cmdletbinding()]
    param([parameter(valuefrompipeline=$true)]
          [validatenotnullorempty()][string]$log,[switch]$err,
          [scriptblock]$ce={!!$_ -and $_.trim() -ne [string]::empty},
          [stringsplitoptions]$REE='removeemptyentries',
          [string]$llbg=@({date -f 'yyyy-MM-dd HH:mm:ss.fffffff'},{' '*27}))
    process{
      chkpars $myinvocation.mycommand $psboundparameters
      $log|%{replace($LNW,$NL.str).split($NL.ach,$REE)}|? $ce|
      %{"$(&$llbg[!!$i]) $(if($err){'!!'}else{'--'}) $_";$i=1}|
      write-host
    }
  }
  function mk_oc{[cmdletbinding()]param([validatenotnullorempty()][string]$cs)
    chkpars $myinvocation.mycommand $psboundparameters
    $oc=new-object oracle.dataaccess.client.oracleconnection $cs
    $oc.open()
    $oc
  }
  function chk_db_pars{[cmdletbinding()]
      param([validatenotnull()][oracle.dataaccess.client.oracleconnection]$oc,
            [validatenotnullorempty()][string]$cft,
            [validatenotnullorempty()][string]$dbr,
            [validatenotnull()][string[]]$om)
    chkpars $myinvocation.mycommand $psboundparameters
    log "В '${dbr}' БД получение информации из V`$DATABASE..."
    $cm.connection=$oc
    $cm.commandtext=@'
select dbid,controlfile_type cft,database_role dbr,log_mode lm,
       open_mode om,resetlogs_change# rl,prior_resetlogs_change# prl
from v$database
'@
    if($da.fill($tbl) -ne 1){throw "Чтение из '$($cm.commandtext)'"}
    $r1=$tbl.rows[0]
    log '... Выполнено'
    log 'Проверка типа управляющего файла...'
    if($r1.cft -ne $cft){
      throw "Тип управляющего файла не '${cft}', а '$($r1.cft)'"
    }
    log '... Выполнено'
    log 'Проверка роли БД...'
    if($r1.dbr -ne $dbr){
      throw "Роль БД не '${dbr}', а '$($r1.dbr)'"
    }
    log '... Выполнено'
    log 'Проверка режима архивирования журналов...'
    if($r1.lm -ne 'ARCHIVELOG'){
      throw "Режим архивирования журналов не 'ARCHIVELOG', а '$($r1.lm)'"
    }
    log '... Выполнено'
    log 'Проверка режима открытия БД...'
    if($om -notcontains $r1.om){
      throw "Режим открытия БД не '${om}', а '$($r1.om)'"
    }
    $r1.dbid,$r1.rl,$r1.prl
    $tbl.reset()
    log '... Выполнено'
  }
  function chk_db_ids{
    log 'Сравнение идентификаторов баз данных...'
    if($prid -ne $sbid){
      throw @"
Идентификаторы 'PRIMARY' БД (${prid}) и 'STANDBY' БД (${sbid}) не равны
"@
    }
    log '... Выполнено'
  }
  function sb_cn{
    $msg="В 'STANDBY' БД получение SCN"
    log "${msg}..."
    $cm.connection=$sboc
    $cm.commandtext=@'
select min(scn) scn
  from (select checkpoint_change# scn from v$datafile_header
         union all
        select checkpoint_change# from v$datafile
         union all
        select current_scn
/*               case
                 when current_scn is null
                   or current_scn > checkpoint_change#
                 then checkpoint_change#
                 else current_scn
               end*/
          from v$database
         where current_scn > 0)
'@
    if($da.fill($tbl) -ne 1){throw $msg}
    $tbl.rows[0].scn
    $tbl.reset()
    log '... Выполнено'
  }
  function chk_db_incs{
    log 'Проверка инкарнаций баз данных...'
    if(($prrl -ne $sbrl -or $prprl -ne $sbprl) -and
       ($prprl -ne $sbrl -or @(($sbcn+2),($sbcn+3)) -notcontains $prrl)){
      throw 'Инкарнации баз данных не совместимы'
    }
    log '... Выполнено'
  }
  $erroractionpreference='stop'
  try{
    $sw=[diagnostics.stopwatch]::startnew()
    $props=@{tran=$null}
    $dt=date
    $dt='{0}_{1:HHmm}' -f (($dt-[datetime]0).days%7+1),$dt
    $sn=$myinvocation.scriptname
    $log=[io.path]::getfilenamewithoutextension($sn)
    $log="$(split-path $sn)\logs\${log}_${dt}.log"
    $LNW=[environment]::newline
    $NL=@{str="`n";ach=[char[]]"`n"}
    $REE=[stringsplitoptions]::removeemptyentries
    $lnbg={date -f 'yyyy-MM-dd HH:mm:ss.fffffff'},{' '*27}
    try{start-transcript $log -f -outv tran|log;$props.tran=$tran}catch{}
    if(!$call){log (gwmi win32_process -f "handle=${pid}").commandline}
    if(!(test-path env:oracle_sid)){throw 'Нет ORACLE_SID'}
    $sqlp=gcm sqlplus.exe
    [void][reflection.assembly]::loadwithpartialname('Oracle.DataAccess')
    log "Подключение к 'PRIMARY' БД..."
    $cs='user id=/;dba privilege=sysdba'
    dispose-after($proc=mk_oc "data source=primary_ekr;${cs}"){
      log '... Выполнено'
      dispose-after($cm=new-object oracle.dataaccess.client.oraclecommand){
        dispose-after(
          $da=new-object oracle.dataaccess.client.oracledataadapter){
          $da.selectcommand=$cm
          dispose-after($tbl=new-object data.datatable){
            $om=@('MOUNTED','READ WRITE','READ ONLY')
            $prid,$prrl,$prprl=chk_db_pars $proc CURRENT PRIMARY $om
            log "Подключение к 'STANDBY' БД..."
            dispose-after($sboc=mk_oc $cs){
              log '... Выполнено'
              $sbid,$sbrl,$sbprl=chk_db_pars $sboc STANDBY 'PHYSICAL STANDBY' `
                                             @('MOUNTED')
              chk_db_ids
              $sbcn=sb_cn
              chk_db_incs
            }
          }
        }
      }
    }
    $scr=@'
whenever oserror exit failure rollback;
whenever sqlerror exit sql.sqlcode rollback;
conn /@primary_ekr as sysdba;
alter system set audit_trail=os scope=spfile;
shutdown immediate;
startup restrict open read only;
alter system archive log current noswitch;
whenever oserror continue none;
whenever sqlerror continue none;
shutdown immediate;
whenever oserror exit failure rollback;
whenever sqlerror exit sql.sqlcode rollback;
startup mount;
'@
    log $scr
    if($activate){
      $msr=gcm "$(split-path $sn)\manual_standby_recovery.ps1"
      $scr="${scr}${LNW}exit${LNW}"
      $chkempty={!!$_ -and $_.trim() -ne [string]::empty}
      $scr|&$sqlp -sl /nolog|? $chkempty|log
      if($lastexitcode -ne 0){
        throw "Ошибка '${lastexitcode}' выполнения 'sqlplus.exe'"
      }
      &$msr -call
    }
    $scr=@'
whenever oserror exit failure rollback;
whenever sqlerror exit sql.sqlcode rollback;
conn /as sysdba;
alter database activate standby database;
alter system set audit_trail=db,extended scope=spfile;
whenever oserror continue none;
whenever sqlerror continue none;
shutdown immediate;
whenever oserror exit failure rollback;
whenever sqlerror exit sql.sqlcode rollback;
startup;
select controlfile_type,database_role,open_mode from v$database;
conn /@primary_ekr as sysdba;
alter database convert to physical standby;
whenever oserror continue none;
whenever sqlerror continue none;
shutdown immediate;
whenever oserror exit failure rollback;
whenever sqlerror exit sql.sqlcode rollback;
startup mount;
set serveroutput on size 1000000;
declare
  sqls varchar2(1024);
begin
  for r in(select to_char(group#) g from v$log order by group#) loop
    sqls:='alter database clear logfile group '||r.g;
    dbms_output.put_line(sqls||';');
    execute immediate sqls;
  end loop;
end;
/
select controlfile_type,database_role,open_mode from v$database;
'@
    log $scr
    if($activate){
      $scr="${scr}${LNW}exit${LNW}"
      $scr|&$sqlp -sl /nolog|? $chkempty|log
      if($lastexitcode -ne 0){
        throw "Ошибка '${lastexitcode}' выполнения 'sqlplus.exe'"
      }
    }
    if(!$call){log "Затрачено '$($sw.elapsed)'";exit 0}
  }catch{if($call){throw}else{$_|out-string|log -err;exit 1}}
   finally{if($props.tran){stop-transcript >$null}}
}
