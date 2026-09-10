using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace HallE.Windows.UI;

public sealed class ProjectNameDialog : Window
{
    private readonly TextBox _nameBox;

    public string ProjectName => _nameBox.Text.Trim();

    public ProjectNameDialog(Window owner)
    {
        Owner = owner;
        Title = "New project — Hall-e";
        Width = 430;
        Height = 220;
        MinWidth = 380;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = (Brush)Application.Current.Resources["BackgroundBrush"];
        Foreground = (Brush)Application.Current.Resources["TextBrush"];
        ShowInTaskbar = false;

        var root = new Grid { Margin = new Thickness(22) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var title = new TextBlock
        {
            Text = "Create a project",
            FontSize = 20,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 7)
        };
        root.Children.Add(title);

        var help = new TextBlock
        {
            Text = "Projects keep related meetings together in your local library.",
            Foreground = (Brush)Application.Current.Resources["MutedTextBrush"],
            Margin = new Thickness(0, 0, 0, 14)
        };
        Grid.SetRow(help, 1);
        root.Children.Add(help);

        _nameBox = new TextBox
        {
            MaxLength = 80,
            VerticalAlignment = VerticalAlignment.Top
        };
        AutomationProperties.SetName(_nameBox, "Project name");
        Grid.SetRow(_nameBox, 2);
        root.Children.Add(_nameBox);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        var cancel = new Button
        {
            Content = "Cancel",
            Style = (Style)Application.Current.Resources["SecondaryButton"],
            Margin = new Thickness(0, 0, 8, 0),
            IsCancel = true
        };
        var create = new Button
        {
            Content = "Create project",
            IsDefault = true
        };
        create.Click += (_, _) => Accept();
        buttons.Children.Add(cancel);
        buttons.Children.Add(create);
        Grid.SetRow(buttons, 3);
        root.Children.Add(buttons);

        Content = root;
        Loaded += (_, _) => _nameBox.Focus();
        _nameBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                Accept();
                e.Handled = true;
            }
        };
    }

    private void Accept()
    {
        if (string.IsNullOrWhiteSpace(ProjectName))
        {
            MessageBox.Show(this, "Enter a project name.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        DialogResult = true;
    }
}
