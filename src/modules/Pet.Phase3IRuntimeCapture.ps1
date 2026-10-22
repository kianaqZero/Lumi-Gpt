Set-StrictMode -Version 2

function Initialize-Phase3IRuntimeCaptureWriterType {
    if ('Phase3IRuntimeCaptureWriter' -as [type]) { return }
    $source = @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Media.Imaging;

public sealed class Phase3IRuntimeCaptureWriter : IDisposable {
    private sealed class Item {
        public readonly int Index;
        public readonly string Timestamp;
        public readonly double ElapsedMilliseconds;
        public readonly BitmapSource Bitmap;
        public Item(int index, string timestamp, double elapsed, BitmapSource bitmap) {
            Index=index; Timestamp=timestamp; ElapsedMilliseconds=elapsed; Bitmap=bitmap;
        }
    }
    private readonly BlockingCollection<Item> queue = new BlockingCollection<Item>(8);
    private readonly string directory;
    private readonly StreamWriter timeline;
    private readonly Thread worker;
    private int nextIndex;
    private int writtenCount;
    private int droppedCount;
    private int failureCount;
    private int disposed;
    private string lastError = "";
    public Phase3IRuntimeCaptureWriter(string frameDirectory, string timelinePath) {
        directory=Path.GetFullPath(frameDirectory);
        Directory.CreateDirectory(directory);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(timelinePath)));
        timeline=new StreamWriter(new FileStream(timelinePath,FileMode.Create,FileAccess.Write,FileShare.Read),new UTF8Encoding(false));
        timeline.WriteLine("frame_index\tcaptured_local\telapsed_ms\tfile\twidth\theight");
        timeline.Flush();
        worker=new Thread(WriteLoop);
        worker.IsBackground=true;
        worker.Name="Phase3I-WPF-FrameWriter";
        worker.Start();
    }
    public int EnqueuedCount { get { return nextIndex; } }
    public int WrittenCount { get { return writtenCount; } }
    public int DroppedCount { get { return droppedCount; } }
    public int FailureCount { get { return failureCount; } }
    public string LastError { get { return lastError; } }
    public bool WriterAlive { get { return worker.IsAlive; } }
    public bool TryWrite(BitmapSource bitmap, string timestamp, double elapsedMilliseconds) {
        if (bitmap==null || Volatile.Read(ref disposed)!=0) return false;
        if (!bitmap.IsFrozen) throw new InvalidOperationException("Runtime capture bitmap must be frozen before background encoding.");
        int index=Interlocked.Increment(ref nextIndex);
        if (!queue.TryAdd(new Item(index,timestamp,elapsedMilliseconds,bitmap))) {
            Interlocked.Increment(ref droppedCount);
            return false;
        }
        return true;
    }
    private void WriteLoop() {
        foreach (Item item in queue.GetConsumingEnumerable()) {
            try {
                string name=String.Format("frame_{0:D5}.png",item.Index);
                string path=Path.Combine(directory,name);
                PngBitmapEncoder encoder=new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(item.Bitmap));
                using (FileStream stream=new FileStream(path,FileMode.Create,FileAccess.Write,FileShare.Read)) encoder.Save(stream);
                lock (timeline) {
                    timeline.WriteLine(String.Join("\t",new string[]{item.Index.ToString(),item.Timestamp,item.ElapsedMilliseconds.ToString("F3",System.Globalization.CultureInfo.InvariantCulture),name,item.Bitmap.PixelWidth.ToString(),item.Bitmap.PixelHeight.ToString()}));
                    timeline.Flush();
                }
                Interlocked.Increment(ref writtenCount);
            } catch (Exception ex) {
                Interlocked.Increment(ref failureCount);
                lastError=ex.GetType().FullName+": "+ex.Message;
            }
        }
    }
    public void Dispose() {
        if (Interlocked.Exchange(ref disposed,1)!=0) return;
        queue.CompleteAdding();
        if (!worker.Join(30000)) {
            lastError="Frame writer did not drain within 30 seconds.";
            Interlocked.Increment(ref failureCount);
        }
        lock (timeline) { timeline.Flush(); timeline.Dispose(); }
        queue.Dispose();
    }
}
'@
    $presentationCore = [Windows.Media.Imaging.BitmapSource].Assembly.Location
    $windowsBase = [Windows.Threading.DispatcherTimer].Assembly.Location
    $systemXaml = [System.Xaml.XamlReader].Assembly.Location
    $references = @($presentationCore,$windowsBase,$systemXaml,[System.Collections.Concurrent.BlockingCollection[object]].Assembly.Location)
    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies $references -ErrorAction Stop
}

function Start-Phase3IRuntimeCapture {
    param([Parameter(Mandatory=$true)]$Window,[Parameter(Mandatory=$true)]$Visual,[Parameter(Mandatory=$true)][string]$CaptureRoot)
    Initialize-Phase3IRuntimeCaptureWriterType
    $root=[System.IO.Path]::GetFullPath($CaptureRoot)
    if(Test-Path -LiteralPath $root){
        if(@(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue).Count -gt 0){throw "Refusing to mix runtime-capture artifacts in non-empty path: $root"}
    }else{$null=New-Item -ItemType Directory -Path $root -Force}
    $frames=Join-Path $root 'frames'
    $timeline=Join-Path $root 'frame_timeline.tsv'
    $writer=New-Object Phase3IRuntimeCaptureWriter -ArgumentList @($frames,$timeline)
    $clock=[System.Diagnostics.Stopwatch]::StartNew()
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds(33.333)
    $context=[pscustomobject]@{Window=$Window;Visual=$Visual;Writer=$writer;Timer=$timer;Clock=$clock;CaptureRoot=$root;Width=[int][Math]::Ceiling([double]$Visual.ActualWidth);Height=[int][Math]::Ceiling([double]$Visual.ActualHeight);TickCount=0;CaptureErrors=0;LastCaptureError='';StartedAt=[DateTimeOffset]::Now}
    $timer.Add_Tick({
        try {
            if($context.Width -le 0 -or $context.Height -le 0){throw 'WPF capture visual has zero size.'}
            $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($context.Width,$context.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($context.Visual)
            $bitmap.Freeze()
            $accepted=$context.Writer.TryWrite($bitmap,[DateTimeOffset]::Now.ToString('o'),$context.Clock.Elapsed.TotalMilliseconds)
            $context.TickCount=[int]$context.TickCount+1
            if(-not $accepted){$context.LastCaptureError='bounded writer queue full; frame dropped'}
        } catch {
            $context.CaptureErrors=[int]$context.CaptureErrors+1
            $context.LastCaptureError=$_.Exception.GetType().FullName+': '+$_.Exception.Message
        }
    }.GetNewClosure())
    $timer.Start()
    return $context
}

function Stop-Phase3IRuntimeCapture {
    param([Parameter(Mandatory=$true)]$Context)
    $Context.Timer.Stop()
    $Context.Clock.Stop()
    $Context.Writer.Dispose()
    $summary=[ordered]@{source='WPF RenderTargetBitmap of actual in-process Visual tree on Dispatcher thread';window_title=[string]$Context.Window.Title;started_at=$Context.StartedAt.ToString('o');ended_at=[DateTimeOffset]::Now.ToString('o');canvas_width_px=$Context.Width;canvas_height_px=$Context.Height;target_fps=30;dispatcher_capture_ticks=$Context.TickCount;frames_attempted=[int]$Context.Writer.EnqueuedCount;frames_written=[int]$Context.Writer.WrittenCount;queue_dropped_frames=[int]$Context.Writer.DroppedCount;writer_failures=[int]$Context.Writer.FailureCount;capture_callback_errors=[int]$Context.CaptureErrors;last_capture_error=[string]$Context.LastCaptureError;writer_last_error=[string]$Context.Writer.LastError;capture_root=$Context.CaptureRoot;frame_directory=(Join-Path $Context.CaptureRoot 'frames');timeline=(Join-Path $Context.CaptureRoot 'frame_timeline.tsv');user_visual_confirmed=$false}
    # The caller rewrites the relative frame_directory to the known CaptureRoot to avoid relying on assembly location.
    return $summary
}
