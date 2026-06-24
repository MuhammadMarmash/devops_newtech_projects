"""
Unit tests for TodoManager business logic
"""

import pytest
from datetime import datetime
from business_logic import TodoManager


class TestTodoManager:
    """Test cases for TodoManager class"""
    
    def setup_method(self):
        """Set up test fixtures before each test"""
        self.manager = TodoManager()
    
    def test_create_todo_success(self):
        """Test creating a todo successfully"""
        todo = self.manager.create_todo("Test Todo", "Test Description")
        
        assert todo["id"] == 1
        assert todo["title"] == "Test Todo"
        assert todo["description"] == "Test Description"
        assert todo["completed"] is False
        assert "created_at" in todo
        assert "updated_at" in todo
    
    def test_create_todo_without_description(self):
        """Test creating a todo without description"""
        todo = self.manager.create_todo("Test Todo")
        
        assert todo["title"] == "Test Todo"
        assert todo["description"] == ""
    
    def test_create_todo_empty_title_raises_error(self):
        """Test that empty title raises ValueError"""
        with pytest.raises(ValueError, match="Title cannot be empty"):
            self.manager.create_todo("")
    
    def test_create_todo_whitespace_title_raises_error(self):
        """Test that whitespace-only title raises ValueError"""
        with pytest.raises(ValueError, match="Title cannot be empty"):
            self.manager.create_todo("   ")
    
    def test_create_todo_strips_whitespace(self):
        """Test that whitespace is stripped from title and description"""
        todo = self.manager.create_todo("  Test Todo  ", "  Test Desc  ")
        
        assert todo["title"] == "Test Todo"
        assert todo["description"] == "Test Desc"
    
    def test_create_multiple_todos_increments_id(self):
        """Test that creating multiple todos increments IDs"""
        todo1 = self.manager.create_todo("Todo 1")
        todo2 = self.manager.create_todo("Todo 2")
        todo3 = self.manager.create_todo("Todo 3")
        
        assert todo1["id"] == 1
        assert todo2["id"] == 2
        assert todo3["id"] == 3
    
    def test_get_todo_success(self):
        """Test getting an existing todo"""
        created = self.manager.create_todo("Test Todo")
        retrieved = self.manager.get_todo(created["id"])
        
        assert retrieved is not None
        assert retrieved["id"] == created["id"]
        assert retrieved["title"] == created["title"]
    
    def test_get_todo_not_found(self):
        """Test getting a non-existent todo returns None"""
        result = self.manager.get_todo(999)
        
        assert result is None
    
    def test_get_all_todos_empty(self):
        """Test getting all todos when none exist"""
        todos = self.manager.get_all_todos()
        
        assert todos == []
    
    def test_get_all_todos_multiple(self):
        """Test getting all todos with multiple items"""
        self.manager.create_todo("Todo 1")
        self.manager.create_todo("Todo 2")
        self.manager.create_todo("Todo 3")
        
        todos = self.manager.get_all_todos()
        
        assert len(todos) == 3
        assert todos[0]["title"] == "Todo 1"
        assert todos[1]["title"] == "Todo 2"
        assert todos[2]["title"] == "Todo 3"
    
    def test_update_todo_title(self):
        """Test updating todo title"""
        todo = self.manager.create_todo("Original Title")
        updated = self.manager.update_todo(todo["id"], title="New Title")
        
        assert updated is not None
        assert updated["title"] == "New Title"
        assert updated["description"] == ""
    
    def test_update_todo_description(self):
        """Test updating todo description"""
        todo = self.manager.create_todo("Title", "Original Desc")
        updated = self.manager.update_todo(todo["id"], description="New Desc")
        
        assert updated is not None
        assert updated["title"] == "Title"
        assert updated["description"] == "New Desc"
    
    def test_update_todo_completed(self):
        """Test updating todo completion status"""
        todo = self.manager.create_todo("Todo")
        updated = self.manager.update_todo(todo["id"], completed=True)
        
        assert updated is not None
        assert updated["completed"] is True
    
    def test_update_todo_multiple_fields(self):
        """Test updating multiple fields at once"""
        todo = self.manager.create_todo("Original", "Original Desc")
        updated = self.manager.update_todo(
            todo["id"],
            title="New Title",
            description="New Desc",
            completed=True
        )
        
        assert updated is not None
        assert updated["title"] == "New Title"
        assert updated["description"] == "New Desc"
        assert updated["completed"] is True
    
    def test_update_todo_not_found(self):
        """Test updating non-existent todo returns None"""
        result = self.manager.update_todo(999, title="New Title")
        
        assert result is None
    
    def test_update_todo_empty_title_raises_error(self):
        """Test that updating with empty title raises ValueError"""
        todo = self.manager.create_todo("Title")
        
        with pytest.raises(ValueError, match="Title cannot be empty"):
            self.manager.update_todo(todo["id"], title="")
    
    def test_update_todo_invalid_completed_raises_error(self):
        """Test that invalid completed value raises ValueError"""
        todo = self.manager.create_todo("Title")
        
        with pytest.raises(ValueError, match="Completed must be a boolean"):
            self.manager.update_todo(todo["id"], completed="yes")
    
    def test_update_todo_updates_timestamp(self):
        """Test that updating a todo updates the updated_at timestamp"""
        todo = self.manager.create_todo("Title")
        original_updated = todo["updated_at"]
        
        # Small delay to ensure different timestamp
        import time
        time.sleep(0.01)
        
        updated = self.manager.update_todo(todo["id"], title="New Title")
        
        assert updated["updated_at"] != original_updated
    
    def test_delete_todo_success(self):
        """Test deleting an existing todo"""
        todo = self.manager.create_todo("Todo to delete")
        result = self.manager.delete_todo(todo["id"])
        
        assert result is True
        assert self.manager.get_todo(todo["id"]) is None
    
    def test_delete_todo_not_found(self):
        """Test deleting non-existent todo returns False"""
        result = self.manager.delete_todo(999)
        
        assert result is False
    
    def test_get_completed_todos(self):
        """Test getting only completed todos"""
        self.manager.create_todo("Todo 1")
        todo2 = self.manager.create_todo("Todo 2")
        self.manager.create_todo("Todo 3")
        
        self.manager.update_todo(todo2["id"], completed=True)
        
        completed = self.manager.get_completed_todos()
        
        assert len(completed) == 1
        assert completed[0]["title"] == "Todo 2"
    
    def test_get_pending_todos(self):
        """Test getting only pending todos"""
        self.manager.create_todo("Todo 1")
        todo2 = self.manager.create_todo("Todo 2")
        self.manager.create_todo("Todo 3")
        
        self.manager.update_todo(todo2["id"], completed=True)
        
        pending = self.manager.get_pending_todos()
        
        assert len(pending) == 2
        assert pending[0]["title"] == "Todo 1"
        assert pending[1]["title"] == "Todo 3"
    
    def test_count_todos(self):
        """Test counting todos by status"""
        self.manager.create_todo("Todo 1")
        todo2 = self.manager.create_todo("Todo 2")
        self.manager.create_todo("Todo 3")
        todo4 = self.manager.create_todo("Todo 4")
        
        self.manager.update_todo(todo2["id"], completed=True)
        self.manager.update_todo(todo4["id"], completed=True)
        
        counts = self.manager.count_todos()
        
        assert counts["total"] == 4
        assert counts["completed"] == 2
        assert counts["pending"] == 2
