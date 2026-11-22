// BEGIN Claude selfcheck menu v1
let checkRun = null, checkItem = null;
function removeSelfcheckOutput(path) {
    if (path) $.NSFileManager.defaultManager.removeItemAtPathError(path, null);
}
function startSelfcheck() {
    if (checkRun) return;
    let outputPath = null, output = null;
    try {
        const home = ObjC.unwrap($.NSHomeDirectory());
        const task = $.NSTask.alloc.init;
        outputPath = ObjC.unwrap($.NSTemporaryDirectory()) + 'claude-selfcheck-' + ObjC.unwrap($.NSUUID.UUID.UUIDString) + '.txt';
        const attributes = $.NSMutableDictionary.alloc.init;
        attributes.setObjectForKey($(384), $.NSFilePosixPermissions);
        if (!$.NSFileManager.defaultManager.createFileAtPathContentsAttributes(outputPath, $.NSData.data, attributes)) throw Error('output creation failed');
        output = $.NSFileHandle.fileHandleForWritingAtPath(outputPath);
        task.launchPath = '/usr/bin/env';
        task.arguments = ['-u', 'RUBYOPT', '-u', 'RUBYLIB', '/usr/bin/ruby', '-EUTF-8:UTF-8', home + '/.claude-unified/selfcheck.rb'];
        task.standardOutput = output;
        task.standardError = output;
        task.launch;
        output.closeFile;
        output = null;
        checkRun = {task: task, outputPath: outputPath};
        checkItem.enabled = false;
        startItem.enabled = false;
        checkItem.title = '自检中…正在检查并恢复代理';
    } catch (error) {
        if (output) output.closeFile;
        removeSelfcheckOutput(outputPath);
        displayError('无法启动自检。请先安装自检更新包。');
    }
}
function pollSelfcheck() {
    if (!checkRun || checkRun.task.isRunning) return;
    const completed = checkRun;
    checkRun = null;
    checkItem.enabled = true;
    checkItem.title = '一键自检（会关闭 Claude）';
    try {
        const data = $.NSData.dataWithContentsOfFile(completed.outputPath);
        const text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
        const code = Number(completed.task.terminationStatus);
        const alert = $.NSAlert.alloc.init;
        alert.messageText = code === 0 && text && text.trim() ? '自检通过' : (code === 2 ? '自检结束：有未验证项目' : '自检结束：请检查失败或未完成项目');
        alert.informativeText = '逐项结果如下；未验证项目不能视为通过。';
        const scroll = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(0, 0, 680, 380));
        scroll.hasVerticalScroller = true;
        const view = $.NSTextView.alloc.initWithFrame($.NSMakeRect(0, 0, 660, 380));
        view.editable = false;
        view.selectable = true;
        view.verticallyResizable = true;
        view.textContainer.containerSize = $.NSMakeSize(660, 1000000);
        view.textContainer.widthTracksTextView = true;
        view.string = text || '未取得检查结果，不能视为通过。';
        scroll.documentView = view;
        alert.accessoryView = scroll;
        alert.addButtonWithTitle('关闭');
        app.activateIgnoringOtherApps(true);
        alert.runModal;
    } catch (error) {
        displayError('自检进程已结束，但结果显示失败。请从“查看状态和日志”查看最近报告。');
    } finally {
        removeSelfcheckOutput(completed.outputPath);
        updateStatus();
    }
}
// END Claude selfcheck menu v1
